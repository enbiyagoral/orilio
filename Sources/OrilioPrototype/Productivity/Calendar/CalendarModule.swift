import AppKit
import EventKit
import Observation
import UserNotifications

/// Where calendar data comes from. EventKit in the app; a fake in tests.
protocol CalendarSource: Sendable {
    func access() async -> CalendarAccess
    /// Shows the system prompt if access was never decided. Returns the resulting access.
    func requestAccess() async -> CalendarAccess
    func calendars() async -> [CalendarInfo]
    func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

/// EventKit, isolated in an actor: event queries are synchronous and may block, so they never run
/// on the main actor. Only today's range is ever fetched.
actor EventKitSource: CalendarSource {
    private let store = EKEventStore()

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        // Write-only access can't read events, so for Orilio it is the same as denied.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        _ = try? await store.requestFullAccessToEvents()
        return access()
    }

    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "", color: Self.color($0.cgColor))
        }
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map { event in
            CalendarEvent(
                id: "\(event.calendarItemIdentifier)@\(event.startDate.timeIntervalSinceReferenceDate)",
                eventIdentifier: event.eventIdentifier,
                title: event.title?.isEmpty == false ? event.title : "Untitled event",
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                sourceTitle: event.calendar.source?.title ?? "", color: Self.color(event.calendar.cgColor),
                attendeeNames: (event.attendees ?? []).compactMap(\.name),
                meeting: MeetingLinkResolver.resolve(url: event.url, location: event.location, notes: event.notes))
        }
    }

    private static func color(_ cg: CGColor?) -> CalendarColor {
        guard let cg, let srgb = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3 else { return .fallback }
        return CalendarColor(red: c[0], green: c[1], blue: c[2])
    }
}

/// Local meeting reminders. UserNotifications in the app; a recorder in tests.
protocol ReminderScheduler: Sendable {
    func authorize() async -> Bool
    /// Replaces every pending Orilio meeting reminder with these.
    func replaceAll(_ reminders: [MeetingReminder]) async
}

struct MeetingReminder: Equatable, Sendable {
    /// Stable per event and offset, so rescheduling replaces instead of duplicating.
    let id: String
    let fireDate: Date
    let title: String
    let body: String
}

struct LocalNotificationScheduler: ReminderScheduler {
    static let prefix = "orilio.meeting."

    func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func replaceAll(_ reminders: [MeetingReminder]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.interruptionLevel = .timeSensitive // Focus modes still decide whether it shows
            let interval = max(1, reminder.fireDate.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.prefix + reminder.id, content: content, trigger: trigger))
        }
    }
}

enum CalendarKeys {
    static let enabled = "calendar.enabled"
    static let hiddenCalendars = "calendar.hiddenCalendars"
    static let reminderLead = "calendar.reminderLeadMinutes" // -1 off, 0 at start, 5, 10
    static let declined = "calendar.askDeclined"
    static let meetingLead = "calendar.meetingLeadMinutes" // 10, 5 or 0 (at start)
}

/// The Calendar module's state for the views. Nothing happens, and nothing is requested, until the
/// user turns the module on. Refreshes are event-driven: EventKit changes, the day changing, wake,
/// and the next event boundary; never a polling loop.
@MainActor @Observable
final class CalendarModule {
    enum Status: Equatable {
        case off, needsAccess, denied, restricted, ready
    }

    private(set) var status: Status = .off
    private(set) var day = CalendarDay(events: [], now: Date())
    private(set) var calendars: [CalendarInfo] = []
    private(set) var lastUpdated: Date?
    /// The first timed event after today (within a week), for "Nothing else today · Next up".
    private(set) var nextLater: CalendarEvent?

    /// The user chose Not now on the first card; the panel then shows "access off" with Turn on.
    var declined: Bool { defaults.bool(forKey: CalendarKeys.declined) }

    func decline() {
        defaults.set(true, forKey: CalendarKeys.declined)
        status = .off // observable change; the card follows
    }

    @ObservationIgnored private let source: any CalendarSource
    @ObservationIgnored private let reminders: any ReminderScheduler
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(source: any CalendarSource = EventKitSource(), reminders: any ReminderScheduler = LocalNotificationScheduler(),
         defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = Date.init) {
        self.source = source
        self.reminders = reminders
        self.defaults = defaults
        self.now = now
    }

    var isEnabled: Bool { defaults.bool(forKey: CalendarKeys.enabled) }

    var hiddenCalendarIDs: Set<String> {
        Set(defaults.stringArray(forKey: CalendarKeys.hiddenCalendars) ?? [])
    }

    /// Settings › Calendar › "Show an upcoming meeting in the notch", in minutes.
    var meetingLeadMinutes: Int { defaults.object(forKey: CalendarKeys.meetingLead) as? Int ?? 10 }
    var meetingLead: TimeInterval { TimeInterval(meetingLeadMinutes * 60) }

    func setMeetingLead(_ minutes: Int) {
        defaults.set(minutes, forKey: CalendarKeys.meetingLead)
        refresh() // the island re-reads the day; the next wake-up uses the new window
    }

    /// -1 means reminders are off.
    var reminderLeadMinutes: Int {
        defaults.object(forKey: CalendarKeys.reminderLead) as? Int ?? -1
    }

    // MARK: Lifecycle

    /// Called at launch. If the module was turned on before, read state without prompting.
    func start() {
        guard isEnabled else { status = .off; return }
        observe()
        refresh()
    }

    /// The user turned Calendar on: this is the only place that may show the permission prompt.
    func enable() async {
        defaults.set(true, forKey: CalendarKeys.enabled)
        defaults.set(false, forKey: CalendarKeys.declined)
        if await source.access() == .notDetermined { _ = await source.requestAccess() }
        observe()
        await reload()
    }

    func disable() {
        defaults.set(false, forKey: CalendarKeys.enabled)
        stopObserving()
        boundary?.cancel()
        day = CalendarDay(events: [], now: now())
        calendars = []
        status = .off
        Task { await reminders.replaceAll([]) }
    }

    func setCalendar(_ id: String, visible: Bool) {
        var hidden = hiddenCalendarIDs
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        defaults.set(hidden.sorted(), forKey: CalendarKeys.hiddenCalendars)
        refresh()
    }

    func setReminderLead(_ minutes: Int) async {
        defaults.set(minutes, forKey: CalendarKeys.reminderLead)
        if minutes >= 0 { _ = await reminders.authorize() } // asked only when reminders are turned on
        await reload()
    }

    /// Re-reads EventKit. Coalesced: a burst of change notifications runs one fetch.
    func refresh() {
        guard isEnabled else { return }
        refreshing?.cancel()
        refreshing = Task { [weak self] in await self?.reload() }
    }

    func reload() async {
        guard isEnabled else { status = .off; return }
        switch await source.access() {
        case .notDetermined: status = .needsAccess; clear(); return
        case .denied: status = .denied; clear(); return // also covers access revoked in System Settings
        case .restricted: status = .restricted; clear(); return
        case .authorized: break
        }
        let time = now()
        let start = Calendar.current.startOfDay(for: time)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? time.addingTimeInterval(86_400)
        let hidden = hiddenCalendarIDs
        async let fetchedCalendars = source.calendars()
        let events = await source.events(from: start, to: end).filter { !hidden.contains($0.calendarID) }
        let later = Calendar.current.date(byAdding: .day, value: 7, to: end) ?? end
        let upcoming = await source.events(from: end, to: later).first { !$0.isAllDay && !hidden.contains($0.calendarID) }
        guard !Task.isCancelled else { return }
        calendars = await fetchedCalendars
        nextLater = upcoming
        day = CalendarDay(events: events, now: time)
        lastUpdated = time
        status = .ready
        scheduleBoundaryRefresh()
        await scheduleReminders()
    }

    /// The day as of now, without re-reading EventKit (for countdowns between refreshes).
    func dayNow() -> CalendarDay { CalendarDay(events: day.events, now: now()) }

    private func clear() {
        day = CalendarDay(events: [], now: now())
        boundary?.cancel()
        Task { await reminders.replaceAll([]) }
    }

    // MARK: Reminders

    func reminders(for day: CalendarDay) -> [MeetingReminder] {
        let lead = reminderLeadMinutes
        guard lead >= 0 else { return [] }
        return day.timed.compactMap { event in
            let fire = event.start.addingTimeInterval(-Double(lead) * 60)
            guard fire > day.now else { return nil }
            let when = lead == 0 ? "is starting" : "starts in \(lead) min"
            return MeetingReminder(id: "\(event.id)#\(lead)", fireDate: fire, title: event.title,
                                   body: [when, event.meeting?.provider.rawValue].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func scheduleReminders() async {
        await reminders.replaceAll(reminders(for: day))
    }

    // MARK: Event-driven refresh

    private func scheduleBoundaryRefresh() {
        boundary?.cancel()
        let time = now()
        let midnight = Calendar.current.startOfDay(for: time.addingTimeInterval(86_400))
        let target = min(day.nextBoundary(window: meetingLead) ?? midnight, midnight)
        boundary = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, target.timeIntervalSince(time)) + 1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        observers = [
            center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: refresh),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh),
            // Access may have changed in System Settings while Orilio was in the background.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refresh),
        ]
    }

    private func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    // MARK: Actions

    /// Only ever called from the Join button: the link was validated when the event was read.
    func join(_ event: CalendarEvent) {
        guard let link = event.meeting, MeetingLinkResolver.validate(link.url) != nil else { return }
        NSWorkspace.shared.open(link.url)
    }

    func openInCalendar(_ event: CalendarEvent) {
        if let id = event.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) {
            return
        }
        if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendarApp, configuration: .init())
        }
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
}

/// Used where no calendar is wanted (tests, previews): reports "not determined" and never prompts.
struct NoCalendarSource: CalendarSource {
    func access() async -> CalendarAccess { .notDetermined }
    func requestAccess() async -> CalendarAccess { .notDetermined }
    func calendars() async -> [CalendarInfo] { [] }
    func events(from start: Date, to end: Date) async -> [CalendarEvent] { [] }
}

struct NoReminders: ReminderScheduler {
    func authorize() async -> Bool { false }
    func replaceAll(_ reminders: [MeetingReminder]) async {}
}

/// Lets the Settings window reach the app's modules (it is a separate SwiftUI scene).
@MainActor
enum AppModules {
    static var calendar: CalendarModule?
    static var clipboard: ClipboardModule?
    static var modules: ModuleSettings?
    static var library: ScreenshotLibrary?
    static var island: IslandModel?
}
