// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// Music tabs in Chrome (YouTube Music, Spotify, SoundCloud, including installed web apps),
/// reported by Orilio's extension.
/// One session per tab; a tab's session disappears when the tab closes, the host disconnects,
/// or it stops sending heartbeats.
actor BrowserMediaProvider: MediaProvider {
    static let providerID = "chrome"
    static let commandTimeout: Duration = .seconds(3)
    /// A dropped bridge (host or Orilio restart, sleep) usually comes back within a second or two.
    /// Its sessions stay visible this long, but accept no commands until a connection owns them again.
    static let disconnectGrace: TimeInterval = 5

    nonisolated let id = BrowserMediaProvider.providerID
    nonisolated let displayName = "Chrome"
    nonisolated let updates: AsyncStream<MediaProviderUpdate>
    private let output: AsyncStream<MediaProviderUpdate>.Continuation
    /// Socket events, handled strictly in arrival order.
    nonisolated let inbox: AsyncStream<BridgeServer.Event>.Continuation

    /// Sends a message to one host connection. The server in the app, a recorder in tests.
    private let transport: @Sendable (BridgeMessage, Int) -> Void
    private let broadcast: @Sendable (BridgeMessage) -> Void

    private var connections = Set<Int>()
    private var browserNames: [Int: String] = [:]
    /// `connection` is nil while a session waits out `disconnectGrace`.
    private var sessions: [String: (snapshot: MediaSessionSnapshot, connection: Int?, tabId: Int, browser: String)] = [:]
    private var pending: [String: (connection: Int, resume: CheckedContinuation<Result<Void, MediaError>, Never>)] = [:]

    init(transport: @escaping @Sendable (BridgeMessage, Int) -> Void,
         broadcast: @escaping @Sendable (BridgeMessage) -> Void) {
        self.transport = transport
        self.broadcast = broadcast
        (updates, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (events, inbox) = AsyncStream.makeStream(of: BridgeServer.Event.self)
        self.inbox = inbox
        output.yield(MediaProviderUpdate(status: .notRunning, sessions: []))
        // Lives as long as the app, like the other providers.
        Task { [self] in
            for await event in events { await handle(event) }
        }
    }

    /// The production wiring: a socket server feeding this provider.
    static func live() -> (BrowserMediaProvider, BridgeServer)? {
        let box = ServerBox()
        let provider = BrowserMediaProvider(transport: { box.server?.send($0, to: $1) },
                                            broadcast: { box.server?.broadcast($0) })
        let server = BridgeServer { [inbox = provider.inbox] in inbox.yield($0) }
        box.server = server
        do {
            try server.start()
        } catch {
            return nil
        }
        return (provider, server)
    }

    nonisolated func refresh() {
        broadcast(BridgeMessage(type: "resync"))
    }

    func handle(_ event: BridgeServer.Event) {
        switch event {
        case .connected(let connection):
            connections.insert(connection)
        case .disconnected(let connection):
            connections.remove(connection)
            browserNames[connection] = nil
            let deadline = Date().addingTimeInterval(Self.disconnectGrace)
            for (key, entry) in sessions where entry.connection == connection {
                var snapshot = entry.snapshot
                snapshot.expiresAt = min(snapshot.expiresAt ?? deadline, deadline)
                sessions[key] = (snapshot, nil, entry.tabId, entry.browser)
            }
            for (id, entry) in pending where entry.connection == connection {
                resolve(id, .failure(.notRunning))
            }
        case .message(let connection, let message):
            receive(message, from: connection)
        }
        publish()
    }

    func perform(_ command: MediaCommand, on sourceID: String) async throws(MediaError) {
        pruneExpired()
        guard let entry = sessions[sourceID] else { throw .sessionGone }
        // Never send to a connection that is gone; the session is only being kept on screen.
        guard let connection = entry.connection else { throw .notRunning }
        let id = UUID().uuidString
        let (name, position) = BridgeProtocol.command(command)
        let result = await withCheckedContinuation { continuation in
            pending[id] = (connection, continuation)
            var message = BridgeMessage(type: "command", tabId: entry.tabId, id: id, command: name, position: position)
            message.browser = entry.browser
            transport(message, connection)
            Task { [weak self] in
                try? await Task.sleep(for: Self.commandTimeout)
                await self?.resolve(id, .failure(.failed("The browser tab did not respond")))
            }
        }
        try result.get()
    }

    private func receive(_ message: BridgeMessage, from connection: Int) {
        switch message.type {
        case "hello":
            // A (re)started extension: whatever this connection reported before is no longer known.
            sessions = sessions.filter { $0.value.connection != connection }
            browserNames[connection] = BridgeMessage.clean(message.browserName)
        case "session":
            guard let tabId = message.tabId, tabId > 0 else { return }
            let key = BridgeProtocol.sourceID(browser: message.browser, tabId: tabId)
            if let snapshot = message.snapshot(providerID: id, receivedAt: Date(), browserName: browserNames[connection]) {
                // A reconnected bridge re-reports the same key and takes the session over: no duplicates.
                sessions[key] = (snapshot, connection, tabId, BridgeProtocol.validBrowserID(message.browser))
            } else {
                sessions[key] = nil // stopped, or nothing honest to show
            }
        case "removed":
            if let tabId = message.tabId { sessions[BridgeProtocol.sourceID(browser: message.browser, tabId: tabId)] = nil }
        case "result":
            guard let id = message.id, pending[id]?.connection == connection else { return }
            switch (message.ok, message.error) {
            case (true, _): resolve(id, .success(()))
            case (_, "tab-gone"): resolve(id, .failure(.sessionGone))
            case (_, "unsupported"): resolve(id, .failure(.failed("Not supported by this player")))
            case (_, let error): resolve(id, .failure(.failed(error ?? "The browser tab refused the command")))
            }
        default:
            break
        }
    }

    private func resolve(_ id: String, _ result: Result<Void, MediaError>) {
        pending.removeValue(forKey: id)?.resume.resume(returning: result)
    }

    private func pruneExpired() {
        let now = Date()
        sessions = sessions.filter { $0.value.snapshot.isLive(at: now) }
    }

    private func publish() {
        pruneExpired()
        let status: MediaProviderStatus = connections.isEmpty ? .notRunning : .ready
        output.yield(MediaProviderUpdate(status: status, sessions: sessions.values.map(\.snapshot)))
    }
}

/// Lets the provider's transport reach the server created after it. Set once, before the server
/// starts and before any reader exists, which is why it can be unchecked-Sendable.
private final class ServerBox: @unchecked Sendable {
    var server: BridgeServer?
}
