import Darwin
import Foundation

/// The process Chrome starts for `connectNative`. It is Orilio's own executable, launched with the
/// extension origin as its argument. It relays Chrome's stdin/stdout framing to Orilio's socket and back.
/// If Orilio isn't running it keeps trying (backing off to 30 s) for as long as Chrome keeps it alive.
final class NativeMessagingHost: @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private var socketFD: Int32 = -1 // guarded by `lock`
    private let stdoutLock = NSLock()

    init(socketPath: String = BridgeSocket.defaultPath) {
        self.socketPath = socketPath
    }

    /// Chrome passes the calling extension's origin as the first argument.
    static func isHostLaunch(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("chrome-extension://") }
    }

    static func runIfLaunchedByChrome() {
        let arguments = CommandLine.arguments
        guard isHostLaunch(arguments) else { return }
        // Chrome already enforces allowed_origins; refuse anything else anyway.
        guard arguments.contains(BridgeProtocol.extensionOrigin) else { exit(2) }
        signal(SIGPIPE, SIG_IGN)
        NativeMessagingHost().run()
    }

    func run() -> Never {
        Thread.detachNewThread { [self] in connectLoop() }
        readExtensionLoop()
    }

    // MARK: Chrome -> Orilio

    private func readExtensionLoop() -> Never {
        while true {
            guard let header = readExactly(4, from: STDIN_FILENO),
                  let length = NativeMessagingFrame.length(fromHeader: header) else { exit(0) } // Chrome closed us
            guard length > 0, length <= BridgeProtocol.maxMessageBytes,
                  let payload = readExactly(length, from: STDIN_FILENO) else { exit(1) }
            // Forward only what parses as a protocol message; Orilio validates the content again.
            guard let message = try? JSONDecoder().decode(BridgeMessage.self, from: payload),
                  message.v == BridgeProtocol.version, var line = try? JSONEncoder().encode(message) else { continue }
            line.append(0x0A)
            lock.lock()
            let fd = socketFD
            lock.unlock()
            // While Orilio is unreachable, messages are dropped; on reconnect the extension resends everything.
            if fd >= 0, !BridgeSocket.writeAll(fd, line) { disconnect(fd) }
        }
    }

    // MARK: Orilio -> Chrome

    private func connectLoop() {
        var delay: TimeInterval = 0.5
        while true {
            guard let fd = BridgeSocket.connect(to: socketPath) else {
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 30)
                continue
            }
            delay = 0.5
            lock.lock()
            socketFD = fd
            lock.unlock()
            // Orilio may have restarted and lost state: ask every tab to report again.
            writeToExtension(BridgeMessage(type: "resync"))
            relay(from: fd)
            disconnect(fd)
        }
    }

    private func relay(from fd: Int32) {
        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0, let lines = buffer.append(Data(chunk[0..<count])) else { return }
            for line in lines {
                if let message = try? JSONDecoder().decode(BridgeMessage.self, from: line) { writeToExtension(message) }
            }
        }
    }

    private func disconnect(_ fd: Int32) {
        lock.lock()
        if socketFD == fd {
            close(fd)
            socketFD = -1
        }
        lock.unlock()
    }

    private func writeToExtension(_ message: BridgeMessage) {
        guard let payload = try? JSONEncoder().encode(message) else { return }
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        if !BridgeSocket.writeAll(STDOUT_FILENO, NativeMessagingFrame.encode(payload)) { exit(0) }
    }

    private func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n <= 0 { return nil }
            offset += n
        }
        return data
    }
}
