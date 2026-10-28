// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

private func snapshot(_ id: String, provider: String = "p", _ state: PlaybackState, title: String? = nil,
                      kind: MediaKind = .music, foreground: Bool = true, expires: Date? = nil,
                      caps: MediaCapabilities = [.playPause, .next, .previous, .seek]) -> MediaSessionSnapshot {
    MediaSessionSnapshot(sourceID: id, providerID: provider, sourceName: id, title: title ?? "\(id) song",
                         artist: nil, album: nil, artworkURL: nil, state: state, duration: 200, position: 0,
                         positionDate: t0, capabilities: caps, updatedAt: t0, expiresAt: expires,
                         kind: kind, isForeground: foreground)
}

private func update(_ sessions: MediaSessionSnapshot...) -> MediaProviderUpdate {
    MediaProviderUpdate(status: .ready, sessions: sessions)
}

/// A coordinator on a hand-driven clock.
@MainActor
private final class Harness {
    var clock = t0
    lazy var coordinator = MediaCoordinator(providers: [], now: { [unowned self] in self.clock })
    func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }
    var current: String? { coordinator.current?.sourceID }
}

@MainActor
struct ArbitrationTests {
    @Test func singleSource() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .paused)), from: "spotify")
        #expect(h.current == "spotify")
    }

    @Test func secondSourceStartingTakesOverAndThirdTakesOverAgain() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        h.advance(5)
        h.coordinator.ingest(update(snapshot("tab", .playing)), from: "chrome")
        #expect(h.current == "tab")
        h.advance(5)
        h.coordinator.ingest(update(snapshot("music", .playing)), from: "music")
        #expect(h.current == "music")
        #expect(h.coordinator.sessions.count == 3)
    }

    @Test func simultaneousStartsResolveTheSameWayEveryTime() {
        for _ in 0..<20 {
            let h = Harness()
            h.coordinator.ingest(update(snapshot("b", .playing), snapshot("a", .playing)), from: "chrome")
            #expect(h.current == "a")
        }
    }

    @Test func manualSelectionHoldsUntilAutomaticIsChosen() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        h.coordinator.ingest(update(snapshot("tab", .paused)), from: "chrome")
        h.coordinator.select("tab")
        h.advance(10)
        h.coordinator.ingest(update(snapshot("music", .playing)), from: "music") // a new source starts
        #expect(h.current == "tab")
        h.coordinator.select(nil)
        #expect(h.current == "music")
    }

    @Test func backgroundVideoDoesNotTakeOverPlayingMusic() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        h.advance(5)
        h.coordinator.ingest(update(snapshot("yt", .playing, kind: .video, foreground: false)), from: "chrome")
        #expect(h.current == "spotify")
        // The user brings the video tab forward: now it is a deliberate choice.
        h.coordinator.ingest(update(snapshot("yt", .playing, kind: .video, foreground: true)), from: "chrome")
        #expect(h.current == "yt")
    }

    @Test func backgroundVideoStillShowsWhenNothingElsePlays() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .paused)), from: "spotify")
        h.coordinator.ingest(update(snapshot("yt", .playing, kind: .video, foreground: false)), from: "chrome")
        #expect(h.current == "yt")
    }

    @Test func duplicateDeliveryChangesNothing() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        h.advance(5)
        h.coordinator.ingest(update(snapshot("tab", .playing)), from: "chrome")
        h.advance(5)
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify") // same report again
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        #expect(h.current == "tab") // a repeated report is not a new start
    }

    @Test func trackChangeKeepsTheSameSource() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .playing, title: "One")), from: "spotify")
        h.coordinator.ingest(update(snapshot("tab", .paused)), from: "chrome")
        h.coordinator.ingest(update(snapshot("spotify", .playing, title: "Two")), from: "spotify")
        #expect(h.current == "spotify")
        #expect(h.coordinator.current?.title == "Two")
    }
}

@MainActor
struct LifecycleTests {
    @Test func reloadedTabKeepsItsPlaceInsteadOfStealingTheIsland() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("tab", .playing)), from: "chrome")
        h.advance(60)
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify") // started last
        #expect(h.current == "spotify")
        h.coordinator.ingest(update(), from: "chrome") // tab reloads…
        h.advance(1)
        h.coordinator.ingest(update(snapshot("tab", .playing)), from: "chrome") // …and is back
        #expect(h.current == "spotify")
    }

    @Test func sessionGoneLongerThanTheGraceIsNew() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("tab", .playing)), from: "chrome")
        h.advance(5)
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        h.coordinator.ingest(update(), from: "chrome")
        h.advance(MediaCoordinator.reappearGrace + 1)
        h.coordinator.ingest(update(snapshot("tab", .playing)), from: "chrome") // the user started it again
        #expect(h.current == "tab")
    }

    @Test func staleSessionsExpire() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("tab", .playing, expires: t0.addingTimeInterval(60))), from: "chrome")
        h.coordinator.ingest(update(snapshot("spotify", .paused)), from: "spotify")
        #expect(h.current == "tab")
        h.advance(61)
        h.coordinator.ingest(update(snapshot("spotify", .paused)), from: "spotify") // any refresh
        #expect(h.current == "spotify")
        #expect(h.coordinator.sessions.map(\.sourceID) == ["spotify"])
    }

    @Test func wakeKeepsSessionsThatMissedTheirHeartbeats() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("tab", .playing, expires: t0.addingTimeInterval(60))), from: "chrome")
        h.advance(600) // asleep for ten minutes
        h.coordinator.systemDidWake()
        #expect(h.current == "tab") // still shown while the browser reports again
        h.advance(MediaCoordinator.wakeGrace + 1)
        h.coordinator.ingest(update(), from: "spotify") // nothing came back from the tab
        #expect(h.current == nil)
    }

    @Test func providerTerminationClearsItsSessions() {
        let h = Harness()
        h.coordinator.ingest(update(snapshot("spotify", .playing)), from: "spotify")
        h.coordinator.ingest(MediaProviderUpdate(status: .notRunning, sessions: []), from: "spotify")
        #expect(h.current == nil)
        #expect(h.coordinator.statuses["spotify"] == .notRunning)
    }
}

/// Records commands per provider.
private actor Recorder: MediaProvider {
    nonisolated let id: String
    nonisolated let displayName = "Recorder"
    nonisolated let updates: AsyncStream<MediaProviderUpdate>
    private let continuation: AsyncStream<MediaProviderUpdate>.Continuation
    private(set) var received: [String] = []
    private var delay: Duration = .zero

    init(id: String) {
        self.id = id
        (updates, continuation) = AsyncStream.makeStream()
    }

    nonisolated func push(_ sessions: MediaSessionSnapshot...) {
        continuation.yield(MediaProviderUpdate(status: .ready, sessions: sessions))
    }

    func respondAfter(_ delay: Duration) { self.delay = delay }

    func perform(_ command: MediaCommand, on sourceID: String) async throws(MediaError) {
        if delay > .zero { try? await Task.sleep(for: delay) }
        received.append(sourceID)
    }
}

@MainActor
struct RoutingTests {
    private func settle(until done: () -> Bool) async {
        for _ in 0..<500 where !done() { await Task.yield() }
    }

    @Test func commandLandsOnTheSessionTheUserSawEvenIfTheIslandSwitched() async throws {
        let spotify = Recorder(id: "spotify"), chrome = Recorder(id: "chrome")
        let coordinator = MediaCoordinator(providers: [spotify, chrome])
        spotify.push(snapshot("spotify", provider: "spotify", .playing))
        await settle { coordinator.current != nil }
        await spotify.respondAfter(.milliseconds(50)) // a slow Apple Event

        let pause = Task { try await coordinator.send(.pause, to: "spotify") }
        chrome.push(snapshot("tab", provider: "chrome", .playing)) // meanwhile another source starts
        await settle { coordinator.current?.sourceID == "tab" }
        try await pause.value

        #expect(await spotify.received == ["spotify"])
        #expect(await chrome.received.isEmpty)
    }

    @Test func rapidCommandsAllReachTheSameTarget() async throws {
        let spotify = Recorder(id: "spotify")
        let coordinator = MediaCoordinator(providers: [spotify])
        spotify.push(snapshot("spotify", provider: "spotify", .playing))
        await settle { coordinator.current != nil }
        for _ in 0..<5 { try await coordinator.send(.togglePlayPause, to: "spotify") }
        #expect(await spotify.received == Array(repeating: "spotify", count: 5))
    }

    @Test func sameTabIdInTwoBrowsersStaysApart() async throws {
        let sent = SentLog()
        let provider = BrowserMediaProvider(transport: { sent.add($0, $1) }, broadcast: { _ in })
        for (connection, browser, name) in [(1, "aaaa1111", "Chrome"), (2, "bbbb2222", "Brave")] {
            await provider.handle(.connected(connection))
            var hello = BridgeMessage(type: "hello")
            hello.browserName = name
            await provider.handle(.message(connection, hello))
            var session = BridgeMessage(type: "session", tabId: 5) // the same tab id in both browsers
            session.browser = browser
            session.state = "playing"
            session.title = "Song"
            session.capabilities = ["playPause"]
            await provider.handle(.message(connection, session))
        }
        var iterator = provider.updates.makeAsyncIterator()
        let sessions = await iterator.next()?.sessions ?? []
        #expect(Set(sessions.map(\.sourceID)) == ["chrome:aaaa1111:tab:5", "chrome:bbbb2222:tab:5"])
        #expect(Set(sessions.map(\.sourceName)) == ["YouTube Music · Chrome", "YouTube Music · Brave"])

        let command = Task { try await provider.perform(.pause, on: "chrome:bbbb2222:tab:5") }
        for _ in 0..<200 where sent.all.isEmpty { await Task.yield() }
        #expect(sent.all.first?.1 == 2) // Brave's connection, not Chrome's
        #expect(sent.all.first?.0.browser == "bbbb2222")
        command.cancel()
    }

    @Test func browserIdsAreSanitized() {
        #expect(BridgeProtocol.validBrowserID("ABC123") == "abc123")
        #expect(BridgeProtocol.validBrowserID("../etc") == "default")
        #expect(BridgeProtocol.validBrowserID(nil) == "default")
        #expect(BridgeProtocol.validBrowserID(String(repeating: "a", count: 40)) == "default")
    }

    @Test func videoMessagesKeepKindAndVisibility() throws {
        var message = BridgeMessage(type: "session", tabId: 3)
        message.site = "youtube"
        message.state = "playing"
        message.title = "Talk"
        message.kind = "video"
        message.visible = false
        let snapshot = try #require(message.snapshot(providerID: "chrome", receivedAt: Date(), browserName: "Chrome"))
        #expect(snapshot.kind == .video)
        #expect(!snapshot.isForeground)
        #expect(snapshot.sourceName == "YouTube · Chrome")
        #expect(snapshot.artworkURL == nil) // missing artwork is fine; the UI shows a placeholder
    }
}

private final class SentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(BridgeMessage, Int)] = []
    func add(_ message: BridgeMessage, _ connection: Int) { lock.withLock { items.append((message, connection)) } }
    var all: [(BridgeMessage, Int)] { lock.withLock { items } }
}
