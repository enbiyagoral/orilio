// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation
import UserNotifications

/// One focus session. Time is a deadline on the wall clock, never a count of ticks, so a late or
/// missed timer can't make it drift.
struct FocusSession: Codable, Equatable, Sendable {
    let id: UUID
    let duration: TimeInterval
    /// Set while running.
    var endsAt: Date?
    /// Set while paused.
    var remainingWhenPaused: TimeInterval?

    static func start(_ duration: TimeInterval, at now: Date) -> FocusSession {
        FocusSession(id: UUID(), duration: duration, endsAt: now.addingTimeInterval(duration))
    }

    var isRunning: Bool { endsAt != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return remainingWhenPaused ?? duration
    }

    /// 1 at the start, 0 when done.
    func fraction(at now: Date) -> Double { duration > 0 ? remaining(at: now) / duration : 0 }

    func paused(at now: Date) -> FocusSession {
        FocusSession(id: id, duration: duration, remainingWhenPaused: remaining(at: now))
    }

    func resumed(at now: Date) -> FocusSession {
        FocusSession(id: id, duration: duration, endsAt: now.addingTimeInterval(remaining(at: now)))
    }

    /// "25:00", "4:05", "1:30:00".
    static func text(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let (h, m, s) = (total / 3_600, total % 3_600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The end-of-session notification. UserNotifications in the app; a recorder in tests.
protocol FocusNotifier: Sendable {
    func authorize() async -> Bool
    func isAuthorized() async -> Bool
    /// Replaces any pending focus notification.
    func schedule(at date: Date, minutes: Int) async
    func cancel() async
    /// Settings › General › Sounds: a soft chime as the session ends, while Orilio is running.
    @MainActor func chime()
}

extension FocusNotifier {
    @MainActor func chime() {}
}

struct LocalFocusNotifier: FocusNotifier {
    static let id = "orilio.focus.end"

    func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func schedule(at date: Date, minutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Focus session complete"
        content.body = "\(minutes) minutes of focus. Time for a break."
        content.sound = nil // Orilio chimes itself (Settings › General › Sounds)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        // Same identifier every time: adding it again replaces the pending one.
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.id, content: content, trigger: trigger))
    }

    @MainActor func chime() {
        if PreferencesStore.shared.value.sounds { NSSound(named: "Glass")?.play() }
    }

    func cancel() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.id])
    }
}

enum FocusKeys {
    static let session = "focus.session"
    static let breakSession = "focus.break"
    static let minutes = "focus.minutes"
    static let notify = "focus.notify"
    static let completedDay = "focus.completedDay"
    static let completedCount = "focus.completedCount"
}

/// The focus timer.
///
/// Sleep: the deadline is wall-clock time, so a session keeps counting while the Mac sleeps. If it
/// ended during sleep, it completes on wake (the system delivers its notification).
/// Restart: the session is kept in preferences. A paused session comes back paused; a running one
/// keeps its deadline, and if that passed while Orilio wasn't running it counts as completed,
/// without a second notification.
@MainActor @Observable
final class FocusModule {
    static let presets = [25, 50, 90]
    /// Sessions in the day's row of dots.
    static let dailyGoal = 4

    private(set) var session: FocusSession?
    private(set) var minutes: Int
    private(set) var notify: Bool
    /// Notifications were asked for and macOS said no.
    private(set) var notificationsDenied = false
    private(set) var completedToday = 0
    /// When a session ended while the Mac was asleep (noticed more than a minute late): the panel
    /// says so once, with Start another.
    private(set) var endedWhileAsleep: Date?

    func dismissEndedNotice() { endedWhileAsleep = nil }

    /// A break between sessions (the M5 Moments design): 5 minutes, 15 after every fourth session.
    private(set) var breakSession: FocusSession?
    /// What just ended and waits for the user: the card in the island, "Session done" in the ear.
    /// No break starts by itself.
    private(set) var finished: Finished?

    enum Finished: Equatable {
        /// "25 minutes, done · Session 2 of 4": 5 min break · Keep going.
        case session(number: Int, minutes: Int)
        /// "Break's over · Ready for session 3 of 4?": Start 25 min · Done for now.
        case breakOver(next: Int)
    }

    static let cycle = 4
    static func breakMinutes(after number: Int) -> Int { number % cycle == 0 ? 15 : 5 }
    /// 1…4: where today's last completed session falls in its round of four.
    static func cycleNumber(completed: Int) -> Int { (max(1, completed) - 1) % cycle + 1 }

    var isOnBreak: Bool { breakSession != nil }
    /// Something to show in the collapsed island's leading ear.
    var showsInEar: Bool { isActive || isOnBreak || finished != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifier: any FocusNotifier
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var notificationWork: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, notifier: any FocusNotifier = LocalFocusNotifier(),
         now: @escaping @MainActor () -> Date = Date.init) {
        self.defaults = defaults
        self.notifier = notifier
        self.now = now
        minutes = (defaults.object(forKey: FocusKeys.minutes) as? Int) ?? 25
        notify = defaults.bool(forKey: FocusKeys.notify)
        session = defaults.data(forKey: FocusKeys.session).flatMap { try? JSONDecoder().decode(FocusSession.self, from: $0) }
        breakSession = defaults.data(forKey: FocusKeys.breakSession).flatMap { try? JSONDecoder().decode(FocusSession.self, from: $0) }
        completedToday = countForToday()
    }

    /// Restores a running session's timer, or completes it if it ended while Orilio was quit.
    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
        armTimer()
    }

    var isActive: Bool { session != nil }
    var isRunning: Bool { session?.isRunning == true }

    func remaining(at date: Date) -> TimeInterval { session?.remaining(at: date) ?? Double(minutes * 60) }
    func fraction(at date: Date) -> Double { session?.fraction(at: date) ?? 1 }
    func breakRemaining(at date: Date) -> TimeInterval { breakSession?.remaining(at: date) ?? 0 }

    var stateText: String { isRunning ? "focusing" : isActive ? "paused" : "ready" }

    // MARK: Breaks

    /// "5 min break" on the session-done card.
    func startBreak() {
        guard case .session(let number, _) = finished else { return }
        finished = nil
        breakSession = .start(Double(Self.breakMinutes(after: number) * 60), at: now())
        saveBreak()
        armTimer()
    }

    /// "Keep going": the next session right away, no break.
    func keepGoing() {
        finished = nil
        begin()
    }

    /// "Done for now", or the card ignored and closed: back to ready.
    func doneForNow() { finished = nil }

    /// Ends a break early.
    func endBreak() {
        guard breakSession != nil else { return }
        breakSession = nil
        saveBreak()
        armTimer()
    }

    // MARK: Controls

    /// The custom length's steps: 1, 5, 10, 15 … 240.
    static func step(_ minutes: Int, up: Bool) -> Int {
        up ? (minutes < 5 ? 5 : minutes / 5 * 5 + 5) : (minutes <= 5 ? 1 : (minutes - 1) / 5 * 5)
    }

    func setMinutes(_ value: Int) {
        guard !isActive else { return } // the length of a session in progress doesn't change
        minutes = min(240, max(1, value))
        defaults.set(minutes, forKey: FocusKeys.minutes)
    }

    /// Start, pause or resume, depending on the state: the panel's main button.
    func toggle() {
        guard let session else { return begin() }
        session.isRunning ? pause() : resume()
    }

    func begin() {
        endedWhileAsleep = nil
        finished = nil
        if breakSession != nil { endBreak() }
        guard session == nil else { return }
        update(.start(Double(minutes * 60), at: now()))
    }

    func pause() {
        guard let session, session.isRunning else { return }
        // A pause that arrives after the deadline (right after wake, before the timer fired) completes.
        if session.remaining(at: now()) <= 0 { return check() }
        update(session.paused(at: now()))
    }

    func resume() {
        guard let session, !session.isRunning else { return }
        update(session.resumed(at: now()))
    }

    /// Stops the session without counting it.
    func reset() {
        guard session != nil else { return }
        update(nil)
    }

    func setNotify(_ on: Bool) async {
        if on {
            let granted = await notifier.authorize()
            notificationsDenied = !granted
            guard granted else { return }
        }
        notify = on
        defaults.set(on, forKey: FocusKeys.notify)
        await notificationWork?.value
        await syncNotification()
    }

    /// Completes the session if its deadline has passed. Safe to call any number of times: the
    /// session is cleared by the first call, so it completes exactly once.
    func check() {
        checkBreak()
        guard let session, session.isRunning, session.remaining(at: now()) <= 0 else { return }
        var asleep = false
        if let deadline = session.endsAt, FocusCardState.endedWhileAsleep(deadline: deadline, noticedAt: now()) {
            endedWhileAsleep = deadline
            asleep = true
        }
        self.session = nil
        save()
        timer?.invalidate()
        timer = nil
        recordCompletion()
        // Noticed on time: the island opens with the card (see `IslandPositioner`). Ended while the
        // Mac slept: the quiet "Session ended at" state instead, no chime.
        guard !asleep else { return }
        finished = .session(number: Self.cycleNumber(completed: completedToday), minutes: Int(session.duration / 60))
        notifier.chime()
        // The system delivers the pending notification at the deadline; nothing more to post.
    }

    private func checkBreak() {
        guard let breakSession, let endsAt = breakSession.endsAt, breakSession.remaining(at: now()) <= 0 else { return }
        self.breakSession = nil
        saveBreak()
        armTimer()
        guard !FocusCardState.endedWhileAsleep(deadline: endsAt, noticedAt: now()) else { return }
        finished = .breakOver(next: completedToday % Self.cycle + 1)
        notifier.chime()
    }

    // MARK: Internals

    private func update(_ new: FocusSession?) {
        session = new
        save()
        armTimer()
        // One after another, so a quick pause and resume can't leave a stale notification behind.
        notificationWork = Task { [previous = notificationWork] in
            await previous?.value
            await syncNotification()
        }
    }

    /// Waits for notification changes still in flight (tests).
    func settle() async { await notificationWork?.value }

    /// One timer, at the next deadline (a session's or a break's); none while nothing runs.
    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard let endsAt = session?.endsAt ?? breakSession?.endsAt else { return }
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One pending notification for the running session, or none.
    private func syncNotification() async {
        if notify, let session, let endsAt = session.endsAt {
            guard await notifier.isAuthorized() else {
                notificationsDenied = true // turned off in System Settings since; the timer still works
                return
            }
            await notifier.schedule(at: endsAt, minutes: Int(session.duration / 60))
        } else {
            await notifier.cancel()
        }
    }

    private func save() {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: FocusKeys.session)
        } else {
            defaults.removeObject(forKey: FocusKeys.session)
        }
    }

    private func saveBreak() {
        if let breakSession, let data = try? JSONEncoder().encode(breakSession) {
            defaults.set(data, forKey: FocusKeys.breakSession)
        } else {
            defaults.removeObject(forKey: FocusKeys.breakSession)
        }
    }

    /// The local calendar day, so the count resets at the user's midnight.
    private var todayKey: String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    private func countForToday() -> Int {
        defaults.string(forKey: FocusKeys.completedDay) == todayKey ? defaults.integer(forKey: FocusKeys.completedCount) : 0
    }

    private func recordCompletion() {
        completedToday = countForToday() + 1
        defaults.set(todayKey, forKey: FocusKeys.completedDay)
        defaults.set(completedToday, forKey: FocusKeys.completedCount)
    }

    /// The count shown resets at midnight even if nothing completed since.
    func refreshDay() { completedToday = countForToday() }
}
