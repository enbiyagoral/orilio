import Foundation
import Observation

/// Picks the session the island shows. Pure, so every rule is unit-tested.
enum MediaSourceResolver {
    /// How long a source that just stopped playing keeps the island before another one takes over.
    /// Covers the short pause between tracks so the island doesn't flicker between players.
    static let switchGrace: TimeInterval = 2

    static func resolve(
        sessions: [MediaSessionSnapshot],
        manual: String?,
        previous: String?,
        activatedAt: [String: Date],
        stateChangedAt: [String: Date],
        now: Date,
        showPaused: Bool = true
    ) -> String? {
        let live = sessions.filter { $0.isLive(at: now) }
        func find(_ id: String?) -> MediaSessionSnapshot? { id.flatMap { id in live.first { $0.sourceID == id } } }

        // 1. A source the user picked wins for as long as it exists.
        if let manual = find(manual) { return manual.sourceID }

        // 2. Hold a source that only just stopped, so a gap between tracks doesn't hand over.
        if let prev = find(previous), prev.state != .playing,
           let changed = stateChangedAt[prev.sourceID], now.timeIntervalSince(changed) < switchGrace {
            return prev.sourceID
        }

        // 3. Among playing sources, the one that started most recently.
        let playing = live.filter { $0.state == .playing }
        if let best = playing.max(by: { (activatedAt[$0.sourceID] ?? .distantPast) < (activatedAt[$1.sourceID] ?? .distantPast) }) {
            return best.sourceID
        }

        // 4. Nothing playing: stay where we were, else the most recently updated paused source.
        guard showPaused else { return nil }
        if let prev = find(previous) { return prev.sourceID }
        return live.filter { $0.state == .paused }.max { $0.updatedAt < $1.updatedAt }?.sourceID
    }

    /// When the answer could change with no new input (a grace period ends, a session expires).
    static func nextDeadline(sessions: [MediaSessionSnapshot], current: String?,
                             stateChangedAt: [String: Date], now: Date) -> Date? {
        var deadlines = sessions.compactMap(\.expiresAt).filter { $0 > now }
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

    func ingest(_ update: MediaProviderUpdate, from providerID: String) {
        let time = now()
        statuses[providerID] = update.status
        let old = byProvider[providerID] ?? []
        for session in update.sessions {
            let before = old.first { $0.sourceID == session.sourceID }?.state
            guard before != session.state else { continue }
            stateChangedAt[session.sourceID] = time
            if session.state == .playing { activatedAt[session.sourceID] = time }
        }
        for gone in old where !update.sessions.contains(where: { $0.sourceID == gone.sourceID }) {
            activatedAt[gone.sourceID] = nil
            stateChangedAt[gone.sourceID] = nil
        }
        byProvider[providerID] = update.sessions
        refresh()
    }

    /// Asks every provider for fresh state instead of polling; called when the island opens or the Mac wakes.
    func refreshAll() {
        providers.values.forEach { $0.refresh() }
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
        let live = byProvider.values.joined()
            .filter { $0.isLive(at: time) }
            .sorted { ($0.sourceName, $0.sourceID) < ($1.sourceName, $1.sourceID) }
        if live != sessions { sessions = live }

        let id = MediaSourceResolver.resolve(sessions: live, manual: manualSourceID, previous: current?.sourceID,
                                             activatedAt: activatedAt, stateChangedAt: stateChangedAt, now: time)
        let next = live.first { $0.sourceID == id }
        if next != current { current = next }

        // Event-driven: wake once when the answer could change by itself, never on a fixed tick.
        wake?.cancel()
        if let deadline = MediaSourceResolver.nextDeadline(sessions: live, current: current?.sourceID,
                                                           stateChangedAt: stateChangedAt, now: time) {
            wake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(deadline.timeIntervalSince(time)))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
}
