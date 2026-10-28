import Darwin
import Foundation
import Testing
@testable import OrilioPrototype

private func sessionMessage(tab: Int = 7, state: String = "playing", title: String? = "Song",
                            artwork: String? = "https://lh3.googleusercontent.com/abc=w544-h544",
                            capabilities: [String] = ["playPause", "next", "previous", "seek", "focus"],
                            pwa: Bool = false) -> BridgeMessage {
    var message = BridgeMessage(type: "session", tabId: tab)
    message.windowId = 1
    message.state = state
    message.title = title
    message.artist = "Artist"
    message.album = "Album"
    message.artwork = artwork
    message.duration = 200
    message.position = 30
    message.capabilities = capabilities
    message.pwa = pwa
    return message
}

private final class SentMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(BridgeMessage, Int)] = []
    func append(_ message: BridgeMessage, _ connection: Int) { lock.withLock { items.append((message, connection)) } }
    var all: [(BridgeMessage, Int)] { lock.withLock { items } }
}

private func makeProvider() -> (BrowserMediaProvider, SentMessages) {
    let sent = SentMessages()
    let provider = BrowserMediaProvider(transport: { sent.append($0, $1) }, broadcast: { sent.append($0, -1) })
    return (provider, sent)
}

/// The newest update the provider has published.
private func latest(_ provider: BrowserMediaProvider) async -> MediaProviderUpdate? {
    var iterator = provider.updates.makeAsyncIterator()
    return await iterator.next()
}

// MARK: - Message validation

struct BridgeValidationTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func validSessionBecomesSnapshot() throws {
        let snapshot = try #require(sessionMessage().snapshot(providerID: "chrome", receivedAt: now))
        #expect(snapshot.sourceID == "chrome:tab:7")
        #expect(snapshot.sourceName == "YouTube Music · Chrome")
        #expect(snapshot.state == .playing)
        #expect(snapshot.capabilities == [.playPause, .next, .previous, .seek, .focus])
        #expect(snapshot.expiresAt == now.addingTimeInterval(BridgeProtocol.sessionLifetime))
        #expect(snapshot.artworkURL?.host == "lh3.googleusercontent.com")
    }

    @Test func installedWebAppHasPlainName() {
        #expect(sessionMessage(pwa: true).snapshot(providerID: "chrome", receivedAt: now)?.sourceName == "YouTube Music")
    }

    @Test func siteDecidesTheSourceName() {
        var spotify = sessionMessage(artwork: "https://i.scdn.co/image/ab67616d0000b273")
        spotify.site = "spotify"
        let snapshot = spotify.snapshot(providerID: "chrome", receivedAt: now)
        #expect(snapshot?.sourceName == "Spotify · Chrome")
        #expect(snapshot?.artworkURL?.host == "i.scdn.co")

        var soundcloud = sessionMessage(artwork: "https://i1.sndcdn.com/artworks-x-t500x500.jpg", pwa: true)
        soundcloud.site = "soundcloud"
        #expect(soundcloud.snapshot(providerID: "chrome", receivedAt: now)?.sourceName == "SoundCloud")

        var unknown = sessionMessage()
        unknown.site = "example"
        #expect(unknown.snapshot(providerID: "chrome", receivedAt: now) == nil) // unknown sites are refused
    }

    @Test func stoppedOrUntitledSessionsShowNothing() {
        #expect(sessionMessage(state: "stopped").snapshot(providerID: "chrome", receivedAt: now) == nil)
        #expect(sessionMessage(title: "   ").snapshot(providerID: "chrome", receivedAt: now) == nil)
        #expect(sessionMessage(tab: 0).snapshot(providerID: "chrome", receivedAt: now) == nil)
    }

    @Test func wrongProtocolVersionIsRejected() {
        var message = sessionMessage()
        message.v = 2
        #expect(message.snapshot(providerID: "chrome", receivedAt: now) == nil)
    }

    @Test func artworkOnlyFromGoogleImageHosts() {
        #expect(BridgeMessage.artworkURL("https://i.ytimg.com/vi/x/hq.jpg") != nil)
        #expect(BridgeMessage.artworkURL("https://yt3.ggpht.com/a") != nil)
        #expect(BridgeMessage.artworkURL("http://lh3.googleusercontent.com/a") == nil) // not https
        #expect(BridgeMessage.artworkURL("https://evil.example/googleusercontent.com") == nil)
        #expect(BridgeMessage.artworkURL("https://notgoogleusercontent.com/a") == nil)
    }

    @Test func untrustedValuesAreBoundedOrDropped() throws {
        var message = sessionMessage(capabilities: ["playPause", "launchMissiles"])
        message.title = String(repeating: "x", count: 5_000)
        message.duration = .infinity
        message.position = -4
        let snapshot = try #require(message.snapshot(providerID: "chrome", receivedAt: now))
        #expect(snapshot.title.count == BridgeProtocol.maxTextLength)
        #expect(snapshot.capabilities == .playPause)
        #expect(snapshot.duration == nil)
        #expect(snapshot.position == nil)
    }

    @Test func commandNames() {
        #expect(BridgeProtocol.command(.togglePlayPause).name == "toggle")
        #expect(BridgeProtocol.command(.seek(to: -3)) == ("seek", 0))
        #expect(BridgeProtocol.command(.focus).name == "focus")
    }
}

// MARK: - Framing

struct BridgeFramingTests {
    @Test func nativeMessagingFrameRoundTrip() throws {
        let payload = Data(#"{"v":1,"type":"resync"}"#.utf8)
        let frame = NativeMessagingFrame.encode(payload)
        #expect(frame.count == payload.count + 4)
        #expect(NativeMessagingFrame.length(fromHeader: frame.prefix(4)) == payload.count)
        #expect(frame.dropFirst(4) == payload)
    }

    @Test func lineBufferSplitsAndBoundsLines() throws {
        var buffer = LineBuffer()
        let first = buffer.append(Data("a\nb".utf8))
        let second = buffer.append(Data("c\n".utf8))
        let oversized = buffer.append(Data(count: BridgeProtocol.maxMessageBytes + 1))
        #expect(first == [Data("a".utf8)])
        #expect(second == [Data("bc".utf8)])
        #expect(oversized == nil)
    }

    @Test func hostLaunchIsDetectedFromChromeArguments() {
        #expect(NativeMessagingHost.isHostLaunch(["/x/OrilioPrototype", BridgeProtocol.extensionOrigin]))
        #expect(!NativeMessagingHost.isHostLaunch(["/x/OrilioPrototype"]))
    }
}

// MARK: - Provider lifecycle and routing

struct BrowserProviderTests {
    @Test func tabsComeAndGoWithoutDuplicates() async {
        let (provider, _) = makeProvider()
        await provider.handle(.connected(1))
        await provider.handle(.message(1, sessionMessage(tab: 7)))
        await provider.handle(.message(1, sessionMessage(tab: 7, state: "paused"))) // same tab, new state
        await provider.handle(.message(1, sessionMessage(tab: 9)))
        var update = await latest(provider)
        #expect(update?.status == .ready)
        #expect(update?.sessions.map(\.sourceID).sorted() == ["chrome:tab:7", "chrome:tab:9"])
        #expect(update?.sessions.first { $0.sourceID == "chrome:tab:7" }?.state == .paused)

        await provider.handle(.message(1, BridgeMessage(type: "removed", tabId: 9))) // tab closed
        update = await latest(provider)
        #expect(update?.sessions.map(\.sourceID) == ["chrome:tab:7"])
    }

    @Test func helloAndDisconnectClearStaleSessions() async {
        let (provider, _) = makeProvider()
        await provider.handle(.connected(1))
        await provider.handle(.message(1, sessionMessage(tab: 7)))
        await provider.handle(.message(1, BridgeMessage(type: "hello"))) // extension restarted
        #expect(await latest(provider)?.sessions.isEmpty == true)

        await provider.handle(.message(1, sessionMessage(tab: 7)))
        await provider.handle(.disconnected(1)) // Chrome quit
        let update = await latest(provider)
        #expect(update?.sessions.isEmpty == true)
        #expect(update?.status == .notRunning)
    }

    @Test func commandsGoToTheTabsOwnConnectionAndResolve() async throws {
        let (provider, sent) = makeProvider()
        await provider.handle(.connected(1))
        await provider.handle(.connected(2))
        await provider.handle(.message(1, sessionMessage(tab: 7)))
        await provider.handle(.message(2, sessionMessage(tab: 9)))

        let command = Task { try await provider.perform(.next, on: "chrome:tab:9") }
        for _ in 0..<200 where sent.all.isEmpty { await Task.yield() }
        let (message, connection) = try #require(sent.all.first)
        #expect(connection == 2)
        #expect(message.type == "command" && message.tabId == 9 && message.command == "next")

        var result = BridgeMessage(type: "result", id: message.id)
        result.ok = true
        await provider.handle(.message(1, result)) // wrong connection: ignored
        await provider.handle(.message(2, result))
        try await command.value
    }

    @Test func refusedAndUnansweredCommandsFail() async throws {
        let (provider, sent) = makeProvider()
        await provider.handle(.connected(1))
        await provider.handle(.message(1, sessionMessage(tab: 7)))

        let refused = Task { try await provider.perform(.play, on: "chrome:tab:7") }
        for _ in 0..<200 where sent.all.isEmpty { await Task.yield() }
        var result = BridgeMessage(type: "result", id: sent.all.first?.0.id)
        result.ok = false
        result.error = "tab-gone"
        await provider.handle(.message(1, result))
        await #expect(throws: MediaError.sessionGone) { try await refused.value }

        let dropped = Task { try await provider.perform(.pause, on: "chrome:tab:7") }
        for _ in 0..<200 where sent.all.count < 2 { await Task.yield() }
        await provider.handle(.disconnected(1)) // bridge lost mid-command
        await #expect(throws: MediaError.notRunning) { try await dropped.value }

        await #expect(throws: MediaError.sessionGone) { try await provider.perform(.play, on: "chrome:tab:7") }
    }

    @Test func silentTabTimesOut() async {
        let (provider, _) = makeProvider()
        await provider.handle(.connected(1))
        await provider.handle(.message(1, sessionMessage(tab: 7)))
        await #expect(throws: MediaError.failed("The browser tab did not respond")) {
            try await provider.perform(.play, on: "chrome:tab:7")
        }
    }

    @Test func refreshAsksEveryConnectionToResync() async {
        let (provider, sent) = makeProvider()
        provider.refresh()
        #expect(sent.all.map(\.0.type) == ["resync"])
        #expect(sent.all.first?.1 == -1) // broadcast
    }
}

// MARK: - Real socket round trip

struct BridgeSocketTests {
    @Test func serverAndHostTalkOverATrustedSocket() async throws {
        let path = "/tmp/orilio-test-\(getpid()).sock"
        let received = AsyncStream.makeStream(of: BridgeServer.Event.self)
        let server = BridgeServer(path: path) { received.continuation.yield($0) }
        try server.start()
        defer { server.stop() }

        // Owner-only permissions on the socket file.
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0)

        let fd = try #require(BridgeSocket.connect(to: path)) // the peer check passes: same executable
        defer { close(fd) }
        var events = received.stream.makeAsyncIterator()
        guard case .connected(let id) = await events.next() else { Issue.record("no connection"); return }

        #expect(BridgeSocket.writeAll(fd, Data(#"{"v":1,"type":"removed","tabId":3}"#.utf8 + [0x0A])))
        #expect(BridgeSocket.writeAll(fd, Data("not json\n".utf8))) // ignored, not fatal
        guard case .message(id, let message) = await events.next() else { Issue.record("no message"); return }
        #expect(message.type == "removed" && message.tabId == 3)

        server.send(BridgeMessage(type: "resync"), to: id)
        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 1_024)
        let count = read(fd, &chunk, chunk.count)
        let parsed = buffer.append(Data(chunk[0..<max(count, 0)]))
        let lines = try #require(parsed)
        #expect(try JSONDecoder().decode(BridgeMessage.self, from: try #require(lines.first)).type == "resync")
    }
}
