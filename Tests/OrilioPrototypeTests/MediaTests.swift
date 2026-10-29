// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Testing
@testable import OrilioPrototype

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

private func session(_ id: String, provider: String = "p", _ state: PlaybackState,
                     updated: Date = t0, expires: Date? = nil,
                     caps: MediaCapabilities = [.playPause, .next, .previous]) -> MediaSessionSnapshot {
    MediaSessionSnapshot(sourceID: id, providerID: provider, sourceName: id, title: "\(id) song", artist: nil, album: nil,
                         artworkURL: nil, state: state, duration: 200, position: 0, positionDate: updated,
                         capabilities: caps, updatedAt: updated, expiresAt: expires)
}

/// Records commands; can be told to fail like a real provider would.
private actor TestProvider: MediaProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let updates: AsyncStream<MediaProviderUpdate>
    private let continuation: AsyncStream<MediaProviderUpdate>.Continuation
    private(set) var received: [(MediaCommand, String)] = []
    private var failure: MediaError?

    init(id: String) {
        self.id = id
        displayName = id.capitalized
        (updates, continuation) = AsyncStream.makeStream()
    }

    nonisolated func push(_ status: MediaProviderStatus, _ sessions: [MediaSessionSnapshot] = []) {
        continuation.yield(MediaProviderUpdate(status: status, sessions: sessions))
    }

    func fail(with error: MediaError?) { failure = error }

    func perform(_ command: MediaCommand, on sourceID: String) async throws(MediaError) {
        if let failure { throw failure }
        received.append((command, sourceID))
    }
}

@MainActor
private func settle(_ coordinator: MediaCoordinator, until done: () -> Bool) async {
    for _ in 0..<200 where !done() { await Task.yield() }
}

// MARK: - Source resolution rules

struct SourceResolutionTests {
    private func resolve(_ sessions: [MediaSessionSnapshot], manual: String? = nil, previous: String? = nil,
                         activated: [String: Date] = [:], changed: [String: Date] = [:],
                         now: Date = t0, showPaused: Bool = true) -> String? {
        MediaSourceResolver.resolve(sessions: sessions, manual: manual, previous: previous, activatedAt: activated,
                                    stateChangedAt: changed, now: now, showPaused: showPaused)
    }

    @Test func playingBeatsPaused() {
        #expect(resolve([session("a", .paused), session("b", .playing)]) == "b")
    }

    @Test func mostRecentlyActivatedPlayingWins() {
        let activated = ["a": t0, "b": t0.addingTimeInterval(5)]
        #expect(resolve([session("a", .playing), session("b", .playing)], activated: activated) == "b")
    }

    @Test func manualSelectionHoldsUntilItDisappears() {
        let both = [session("a", .paused), session("b", .playing)]
        #expect(resolve(both, manual: "a") == "a")
        #expect(resolve([session("b", .playing)], manual: "a") == "b")
    }

    @Test func briefPauseDoesNotHandOverToAnotherSource() {
        // "a" was playing (activated earlier) and paused at t0, between two tracks.
        let sessions = [session("a", .paused), session("b", .playing)]
        let activated = ["a": t0.addingTimeInterval(-60), "b": t0.addingTimeInterval(-30)]
        let changed = ["a": t0]
        #expect(resolve(sessions, previous: "a", activated: activated, changed: changed,
                        now: t0.addingTimeInterval(0.5)) == "a")
        #expect(resolve(sessions, previous: "a", activated: activated, changed: changed,
                        now: t0.addingTimeInterval(MediaSourceResolver.switchGrace + 0.1)) == "b")
    }

    @Test func nothingPlayingKeepsPreviousOrMostRecentlyPaused() {
        let a = session("a", .paused), b = session("b", .paused)
        let changed = ["a": t0, "b": t0.addingTimeInterval(10)]
        #expect(resolve([a, b], previous: "a", changed: changed) == "a")
        #expect(resolve([a, b], changed: changed) == "b")
        #expect(resolve([a, b], changed: changed, showPaused: false) == nil)
    }

    @Test func refreshedMetadataDoesNotWinOverARecentPause() {
        // The tab re-reported a moment ago (heartbeat), but the app was the one paused last.
        let tab = session("tab", .paused, updated: t0.addingTimeInterval(60))
        let app = session("app", .paused, updated: t0)
        #expect(resolve([tab, app], changed: ["tab": t0, "app": t0.addingTimeInterval(30)]) == "app")
    }

    @Test func expiredSessionsAreIgnored() {
        let stale = session("tab", .playing, expires: t0.addingTimeInterval(-1))
        #expect(resolve([stale, session("app", .paused)]) == "app")
    }

    @Test func nextDeadlineIsEarliestOfExpiryAndGrace() {
        let sessions = [session("tab", .playing, expires: t0.addingTimeInterval(30)), session("app", .paused)]
        let deadline = MediaSourceResolver.nextDeadline(sessions: sessions, current: "app",
                                                        stateChangedAt: ["app": t0], now: t0)
        #expect(deadline == t0.addingTimeInterval(MediaSourceResolver.switchGrace))
    }
}

// MARK: - Coordinator: state transitions, routing, failures

@MainActor
struct MediaCoordinatorTests {
    @Test func startedPlayingSourceTakesOverAfterGrace() async {
        var clock = t0
        let coordinator = MediaCoordinator(providers: [], now: { clock })
        coordinator.ingest(MediaProviderUpdate(status: .ready, sessions: [session("a", .playing)]), from: "p1")
        #expect(coordinator.current?.sourceID == "a")

        clock = t0.addingTimeInterval(10)
        coordinator.ingest(MediaProviderUpdate(status: .ready, sessions: [session("b", .playing)]), from: "p2")
        #expect(coordinator.current?.sourceID == "b") // most recently activated

        clock = t0.addingTimeInterval(20)
        coordinator.ingest(MediaProviderUpdate(status: .ready, sessions: [session("b", .paused)]), from: "p2")
        #expect(coordinator.current?.sourceID == "b") // grace: just paused
    }

    @Test func endedSessionDisappearsAndSelectionFallsBack() {
        let coordinator = MediaCoordinator(providers: [], now: { t0 })
        coordinator.ingest(MediaProviderUpdate(status: .ready, sessions: [session("a", .paused)]), from: "p1")
        coordinator.ingest(MediaProviderUpdate(status: .ready, sessions: [session("b", .paused)]), from: "p2")
        coordinator.select("b")
        #expect(coordinator.current?.sourceID == "b")
        coordinator.ingest(MediaProviderUpdate(status: .notRunning, sessions: []), from: "p2")
        #expect(coordinator.current?.sourceID == "a")
        #expect(coordinator.statuses["p2"] == .notRunning)
    }

    @Test func permissionDeniedIsReportedAndShowsNothing() async {
        let provider = TestProvider(id: "spotify")
        let coordinator = MediaCoordinator(providers: [provider])
        provider.push(.permissionDenied)
        await settle(coordinator) { coordinator.statuses["spotify"] != nil }
        #expect(coordinator.statuses["spotify"] == .permissionDenied)
        #expect(coordinator.current == nil)
    }

    @Test func commandsGoOnlyToTheOwningProvider() async throws {
        let spotify = TestProvider(id: "spotify"), browser = TestProvider(id: "chrome")
        let coordinator = MediaCoordinator(providers: [spotify, browser])
        spotify.push(.ready, [session("com.spotify.client", provider: "spotify", .playing)])
        browser.push(.ready, [session("chrome:tab:1", provider: "chrome", .paused)])
        await settle(coordinator) { coordinator.sessions.count == 2 }

        try await coordinator.send(.next, to: "chrome:tab:1")
        #expect(await browser.received.map(\.1) == ["chrome:tab:1"])
        #expect(await spotify.received.isEmpty)
    }

    @Test func unsupportedCommandIsRefusedBeforeReachingProvider() async {
        let provider = TestProvider(id: "web")
        let coordinator = MediaCoordinator(providers: [provider])
        provider.push(.ready, [session("tab", provider: "web", .playing, caps: [.playPause])])
        await settle(coordinator) { !coordinator.sessions.isEmpty }

        await #expect(throws: MediaError.unsupported(.next)) { try await coordinator.send(.next, to: "tab") }
        #expect(await provider.received.isEmpty)
    }

    @Test func commandToVanishedSessionFails() async {
        let coordinator = MediaCoordinator(providers: [])
        await #expect(throws: MediaError.sessionGone) { try await coordinator.send(.play, to: "gone") }
    }

    @Test func providerFailureSurfacesAsLastError() async {
        let provider = TestProvider(id: "music")
        let coordinator = MediaCoordinator(providers: [provider])
        provider.push(.ready, [session("com.apple.Music", provider: "music", .paused)])
        await settle(coordinator) { !coordinator.sessions.isEmpty }
        await provider.fail(with: .permissionDenied)

        await #expect(throws: MediaError.permissionDenied) { try await coordinator.send(.play, to: "com.apple.Music") }
        #expect(coordinator.lastError == .permissionDenied)
    }
}

// MARK: - Spotify / Music parsing

struct ScriptablePlayerParsingTests {
    @Test func spotifyNotification() {
        let info = PlayerInfo(notification: [
            "Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "Record",
            "Duration": 215_000, "Playback Position": 12.5, "Track ID": "spotify:track:1",
        ])
        #expect(info == PlayerInfo(state: .playing, title: "Song", artist: "Band", album: "Record", duration: 215,
                                   position: 12.5, trackKey: "spotify:track:1", artworkURL: nil))
    }

    @Test func musicNotificationHasNoPosition() {
        let info = PlayerInfo(notification: [
            "Player State": "Paused", "Name": "Song", "Artist": "", "Total Time": 180_000, "PersistentID": 42,
        ])
        #expect(info.state == .paused)
        #expect(info.artist == nil)
        #expect(info.duration == 180)
        #expect(info.position == nil)
        #expect(info.trackKey == "42")
    }

    @Test func scriptResultTrack() {
        let list = NSAppleEventDescriptor.list()
        let items: [NSAppleEventDescriptor] = [
            .init(string: "playing"), .init(string: "Song"), .init(string: "Band"), .init(string: "Record"),
            .init(double: 215_000), .init(double: 30), .init(string: "spotify:track:1"),
            .init(string: "https://i.scdn.co/image/abc"),
        ]
        for (i, item) in items.enumerated() { list.insert(item, at: i + 1) }
        let state = ScriptState(descriptor: list, durationScale: 0.001)
        #expect(state == .track(PlayerInfo(state: .playing, title: "Song", artist: "Band", album: "Record",
                                           duration: 215, position: 30, trackKey: "spotify:track:1",
                                           artworkURL: URL(string: "https://i.scdn.co/image/abc"))))
    }

    @Test func scriptResultPermissionDenied() {
        let list = NSAppleEventDescriptor.list()
        for (i, s) in ["error", "-1743", "Not authorized"].enumerated() { list.insert(.init(string: s), at: i + 1) }
        #expect(ScriptState(descriptor: list, durationScale: 1) == .failed(.permissionDenied))
    }

    @Test func scriptResultStopped() {
        let list = NSAppleEventDescriptor.list()
        list.insert(.init(string: "stopped"), at: 1)
        #expect(ScriptState(descriptor: list, durationScale: 1) == .stopped)
    }

    @Test func errorNumbersMap() {
        #expect(MediaError(scriptErrorNumber: -1743, message: "") == .permissionDenied)
        #expect(MediaError(scriptErrorNumber: -600, message: "") == .notRunning)
        #expect(MediaError(scriptErrorNumber: -1728, message: "x") == .failed("x (-1728)"))
    }

    @Test func commandsNeverTargetAnotherApp() {
        let next = ScriptablePlayer.spotify.commandScript(.next)
        // Asking first never launches a closed (or quitting) app; only then is it told anything.
        #expect(next.hasPrefix("if application id \"com.spotify.client\" is not running then error number -600\ntell application id \"com.spotify.client\""))
        #expect(next.contains("next track"))
        #expect(next.contains("with timeout of 3 seconds"))
        let seek = ScriptablePlayer.music.commandScript(.seek(to: 12.345))
        #expect(seek.hasPrefix("if application id \"com.apple.Music\" is not running then error number -600\ntell application id \"com.apple.Music\""))
        for player in [ScriptablePlayer.spotify, .music] {
            #expect(player.stateScript.hasPrefix("if application id \"\(player.bundleID)\" is not running then"))
        }
        #expect(ScriptablePlayer.music.artworkScript?.hasPrefix("if application id \"com.apple.Music\" is not running then") == true)
        #expect(seek.contains("set player position to 12.35"))
    }
}
