import Foundation
import Observation

/// Picks the session the island shows. Pure, so every rule is unit-tested.
enum MediaSourceResolver {
    /// How long a source that just stopped playing keeps the island before another one takes over.
    /// Covers the short pause between tracks so the island doesn't flicker between players.
    static let switchGrace: TimeInterval = 2

    /// - Parameters:
    ///   - activatedAt: when each source last *started* playing (a transition, not an observation).
    ///   - stateChangedAt: when each source last changed play state.
    ///   - keepAliveUntil: sessions are treated as live until then even if expired (just after wake).
    static func resolve(
        sessions: [MediaSessionSnapshot],
        manual: String?,
        previous: String?,
        activatedAt: [String: Date],
        stateChangedAt: [String: Date],
        now: Date,
        keepAliveUntil: Date? = nil,
        showPaused: Bool = true
    ) -> String? {
        let live = sessions.filter { isLive($0, now: now, keepAliveUntil: keepAliveUntil) }
        func find(_ id: String?) -> MediaSessionSnapshot? { id.flatMap { id in live.first { $0.sourceID == id } } }

        // 1. A source the user picked wins for as long as it exists.
        if let manual = find(manual) { return manual.sourceID }

        // 2. Hold a source that only just stopped playing, so a gap between tracks doesn't hand over.
        //    (Only one that actually played: a source that shows up paused earns no grace.)
        if let prev = find(previous), prev.state != .playing, activatedAt[prev.sourceID] != nil,
           let changed = stateChangedAt[prev.sourceID], now.timeIntervalSince(changed) < switchGrace {
            return prev.sourceID
        }

        // 3. Among playing sources, the one that started most recently. A video in a tab the user
        //    can't see doesn't compete with anything else that plays (a background tab is not intent).
        let playing = live.filter { $0.state == .playing }
        let intended = playing.filter { $0.kind == .music || $0.isForeground }
        let candidates = intended.isEmpty ? playing : intended
        if let best = candidates.max(by: { order($0, $1, by: activatedAt) }) {
            return best.sourceID
        }

        // 4. Nothing playing: stay where we were, else the source that paused most recently.
        //    Ranked by the transition, never by the last refresh (browsers re-report every 25 s).
        guard showPaused else { return nil }
        if let prev = find(previous) { return prev.sourceID }
        return live.filter { $0.state == .paused }.max { order($0, $1, by: stateChangedAt) }?.sourceID
    }

    static func isLive(_ session: MediaSessionSnapshot, now: Date, keepAliveUntil: Date?) -> Bool {
        session.isLive(at: now) || keepAliveUntil.map { now < $0 } == true
    }

    /// Earlier transition first; ties broken by id so simultaneous starts always resolve the same way.
    private static func order(_ a: MediaSessionSnapshot, _ b: MediaSessionSnapshot, by times: [String: Date]) -> Bool {
        let ta = times[a.sourceID] ?? .distantPast, tb = times[b.sourceID] ?? .distantPast
        return ta != tb ? ta < tb : a.sourceID > b.sourceID
    }

    /// When the answer could change with no new input (a grace period ends, a session expires).
    static func nextDeadline(sessions: [MediaSessionSnapshot], current: String?,
                             stateChangedAt: [String: Date], now: Date, keepAliveUntil: Date? = nil) -> Date? {
        var deadlines = sessions.compactMap(\.expiresAt).filter { $0 > now }
        if let keepAliveUntil, keepAliveUntil > now { deadlines.append(keepAliveUntil) }
        if let current, let changed = stateChangedAt[current] {
            let graceEnd = changed.addingTimeInterval(switchGrace)
            if graceEnd > now { deadlines.append(graceEnd) }
        }
        return deadlines.min()
    }
}

/// Owns every provider's sessions and routes commands. Independent of SwiftUI; views only read it.
@MainActor @Observable
final class MediaCoordinator {
    /// Live sessions, stable order for the source picker.
    private(set) var sessions: [MediaSessionSnapshot] = []
    private(set) var current: MediaSessionSnapshot?
    private(set) var statuses: [String: MediaProviderStatus] = [:]
    /// nil = automatic.
    private(set) var manualSourceID: String?
    private(set) var lastError: MediaError?

    @ObservationIgnored private var providers: [String: any MediaProvider] = [:]
    @ObservationIgnored private var byProvider: [String: [MediaSessionSnapshot]] = [:]
    @ObservationIgnored private var activatedAt: [String: Date] = [:]
    @ObservationIgnored private var stateChangedAt: [String: Date] = [:]
    /// Timing of sessions that just disappeared. A tab reload or a bridge reconnect brings the same
    /// session back within seconds; it must keep its place, not count as newly started.
    @ObservationIgnored private var retired: [String: (state: PlaybackState, activated: Date?, changed: Date?, at: Date)] = [:]
    /// Just after wake, browser sessions have missed their heartbeats; keep them until they report again.
    @ObservationIgnored private var keepAliveUntil: Date?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored let now: @MainActor () -> Date

    init(providers: [any MediaProvider], now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
        for provider in providers {
            self.providers[provider.id] = provider
            listeners.append(Task { [weak self] in
                for await update in provider.updates {
                    self?.ingest(update, from: provider.id)
                }
            })
        }
    }

    deinit {
        listeners.forEach { $0.cancel() }
        wake?.cancel()
    }

    func providerName(_ providerID: String) -> String { providers[providerID]?.displayName ?? providerID }

    /// Continue on "Let Orilio control …?" (the Automation prompt for that app).
    func requestControl(_ providerID: String) async { await providers[providerID]?.requestControl() }

    static let reappearGrace: TimeInterval = 30
    static let wakeGrace: TimeInterval = 15

    func ingest(_ update: MediaProviderUpdate, from providerID: String) {
        let time = now()
        statuses[providerID] = update.status
        retired = retired.filter { time.timeIntervalSince($0.value.at) < Self.reappearGrace }
        let old = byProvider[providerID] ?? []
        for session in update.sessions {
            let id = session.sourceID
            var before = old.first { $0.sourceID == id }?.state
            if before == nil, let back = retired.removeValue(forKey: id) {
                // The same session returning: restore its history instead of treating it as new.
                activatedAt[id] = back.activated
                stateChangedAt[id] = back.changed
                before = back.state
            }
            guard before != session.state else { continue }
            stateChangedAt[id] = time
            if session.state == .playing { activatedAt[id] = time }
        }
        for gone in old where !update.sessions.contains(where: { $0.sourceID == gone.sourceID }) {
            let id = gone.sourceID
            retired[id] = (gone.state, activatedAt.removeValue(forKey: id), stateChangedAt.removeValue(forKey: id), time)
        }
        byProvider[providerID] = update.sessions
        refresh()
    }

    /// Asks every provider for fresh state instead of polling; called when the island opens.
    func refreshAll() {
        providers.values.forEach { $0.refresh() }
    }

    /// The Mac woke or the screen unlocked: keep what we had briefly, and ask everyone to report again.
    func systemDidWake() {
        keepAliveUntil = now().addingTimeInterval(Self.wakeGrace)
        refreshAll()
        refresh()
    }

    /// nil returns to automatic selection.
    func select(_ sourceID: String?) {
        manualSourceID = sourceID
        refresh()
    }

    /// Commands name their target explicitly, so a click lands on the session the user saw
    /// even if the island switched sources a moment earlier.
    func send(_ command: MediaCommand, to sourceID: String) async throws(MediaError) {
        do throws(MediaError) {
            guard let session = sessions.first(where: { $0.sourceID == sourceID }),
                  let provider = providers[session.providerID] else { throw MediaError.sessionGone }
            guard session.capabilities.contains(command.requires) else { throw MediaError.unsupported(command) }
            try await provider.perform(command, on: sourceID)
            lastError = nil
        } catch {
            lastError = error
            throw error
        }
    }

    private func refresh() {
        let time = now()
        if let until = keepAliveUntil, time >= until { keepAliveUntil = nil }
        let live = byProvider.values.joined()
            .filter { MediaSourceResolver.isLive($0, now: time, keepAliveUntil: keepAliveUntil) }
            .sorted { ($0.sourceName, $0.sourceID) < ($1.sourceName, $1.sourceID) }
        if live != sessions { sessions = live }

        let id = MediaSourceResolver.resolve(sessions: live, manual: manualSourceID, previous: current?.sourceID,
                                             activatedAt: activatedAt, stateChangedAt: stateChangedAt, now: time,
                                             keepAliveUntil: keepAliveUntil)
        let next = live.first { $0.sourceID == id }
        if next != current { current = next }

        // Event-driven: wake once when the answer could change by itself, never on a fixed tick.
        wake?.cancel()
        if let deadline = MediaSourceResolver.nextDeadline(sessions: live, current: current?.sourceID,
                                                           stateChangedAt: stateChangedAt, now: time,
                                                           keepAliveUntil: keepAliveUntil) {
            wake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(deadline.timeIntervalSince(time)))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
}
