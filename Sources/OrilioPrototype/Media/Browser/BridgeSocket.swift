import Darwin
import Foundation

/// Local IPC between Orilio and its native messaging host: a Unix domain socket in a
/// user-only directory. No TCP port is opened. Both ends check that the peer runs as the
/// same user *and* from the same executable, so other local programs can't talk to either side.
enum BridgeSocket {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Orilio/bridge.sock").path
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The peer must be this user, running this very executable.
    static func peerIsTrusted(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              let peer = executablePath(of: pid), let me = executablePath(of: getpid()) else { return false }
        return peer == me
    }

    /// Connects to a listening Orilio. Returns a trusted socket or nil.
    static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, peerIsTrusted(fd) else {
            close(fd)
            return nil
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}

/// Splits a byte stream into newline-delimited messages, refusing unbounded lines.
struct LineBuffer {
    private var pending = Data()

    /// Returns complete lines, or nil if a line grew past the limit (the connection should be dropped).
    mutating func append(_ data: Data) -> [Data]? {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
        return pending.count > BridgeProtocol.maxMessageBytes ? nil : lines
    }
}

/// Orilio's side: accepts host connections and hands messages to the browser provider.
final class BridgeServer: @unchecked Sendable {
    enum Event: Sendable {
        case connected(Int)
        case message(Int, BridgeMessage)
        case disconnected(Int)
    }

    // All mutable state is confined to `queue`.
    private let queue = DispatchQueue(label: "com.enbiyagoral.orilio.bridge")
    private let path: String
    private let onEvent: @Sendable (Event) -> Void
    private var listener: DispatchSourceRead?
    private var connections: [Int: (fd: Int32, source: DispatchSourceRead, buffer: LineBuffer)] = [:]
    private var nextID = 1

    init(path: String = BridgeSocket.defaultPath, onEvent: @escaping @Sendable (Event) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        unlink(path) // a stale socket from a previous run
        guard var address = BridgeSocket.address(path) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for id in connections.keys { drop(id) }
        }
        unlink(path)
    }

    func send(_ message: BridgeMessage, to id: Int) {
        guard let encoded = try? JSONEncoder().encode(message) else { return }
        let line = encoded + [0x0A]
        queue.async { [weak self] in
            guard let self, let fd = self.connections[id]?.fd else { return }
            if !BridgeSocket.writeAll(fd, line) { self.drop(id) }
        }
    }

    func broadcast(_ message: BridgeMessage) {
        queue.async { [weak self] in
            guard let self else { return }
            for id in self.connections.keys { self.send(message, to: id) }
        }
    }

    private func accept(on listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard BridgeSocket.peerIsTrusted(fd) else {
            close(fd)
            return
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let id = nextID
        nextID += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(id) }
        source.setCancelHandler { close(fd) }
        connections[id] = (fd, source, LineBuffer())
        source.resume()
        onEvent(.connected(id))
    }

    private func read(_ id: Int) {
        guard var connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        if count == 0 || (count < 0 && errno != EAGAIN) { return drop(id) }
        guard count > 0 else { return }
        guard let lines = connection.buffer.append(Data(chunk[0..<count])) else { return drop(id) }
        connections[id] = connection
        let decoder = JSONDecoder()
        for line in lines {
            // Malformed messages are ignored, not trusted and not fatal.
            if let message = try? decoder.decode(BridgeMessage.self, from: line), message.v == BridgeProtocol.version {
                onEvent(.message(id, message))
            }
        }
    }

    private func drop(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
        onEvent(.disconnected(id))
    }
}
