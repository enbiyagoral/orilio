import Foundation
import Testing
@testable import OrilioPrototype

private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000) // a fixed "now"

private func event(_ title: String, startsIn minutes: Double, lasting duration: Double = 30, calendar: String = "work",
                   allDay: Bool = false, link: String? = nil) -> CalendarEvent {
    let start = noon.addingTimeInterval(minutes * 60)
    return CalendarEvent(id: "\(title)@\(minutes)", eventIdentifier: title, title: title, start: start,
                         end: start.addingTimeInterval(duration * 60), isAllDay: allDay, calendarID: calendar,
                         calendarTitle: calendar, sourceTitle: "Google", color: .fallback, attendeeNames: [],
                         meeting: link.flatMap(URL.init(string:)).flatMap(MeetingLinkResolver.validate))
}

// MARK: - Meeting links

struct MeetingLinkTests {
    @Test func validLinksFromEachProvider() {
        #expect(MeetingLinkResolver.validate(URL(string: "https://meet.google.com/abc-defg-hij")!)?.provider == .googleMeet)
        #expect(MeetingLinkResolver.validate(URL(string: "https://us02web.zoom.us/j/81234567890?pwd=x")!)?.provider == .zoom)
        #expect(MeetingLinkResolver.validate(URL(string: "https://zoom.us/my/someone")!)?.provider == .zoom)
        #expect(MeetingLinkResolver.validate(URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x")!)?.provider == .teams)
        #expect(MeetingLinkResolver.validate(URL(string: "https://teams.live.com/meet/9876")!)?.provider == .teams)
    }

    @Test func untrustedOrMalformedLinksAreRejected() {
        for text in [
            "http://meet.google.com/abc-defg-hij",          // not https
            "https://meet.google.com.evil.example/abc-defg-hij", // lookalike host
            "https://evilzoom.us/j/123",                   // lookalike domain
            "https://zoom.us.attacker.com/j/123",
            "https://meet.google.com/landing",             // not a meeting code
            "https://user:pass@zoom.us/j/123",              // credentials in the URL
            "javascript:alert(1)",
            "file:///Applications/Calculator.app",
            "zoommtg://zoom.us/join?confno=123",            // app schemes are never opened directly
        ] {
            #expect(URL(string: text).flatMap(MeetingLinkResolver.validate) == nil, "\(text)")
        }
    }

    @Test func linksAreFoundInLocationOrNotesButTheEventURLComesFirst() {
        let notes = "Join us!\nhttps://example.com/agenda\nMeeting: https://meet.google.com/xyz-abcd-efg\nDial-in: +1 555"
        #expect(MeetingLinkResolver.resolve(url: nil, location: "Room 4", notes: notes)?.url.absoluteString
                == "https://meet.google.com/xyz-abcd-efg")
        let own = URL(string: "https://zoom.us/j/111")!
        #expect(MeetingLinkResolver.resolve(url: own, location: nil, notes: notes)?.provider == .zoom)
        #expect(MeetingLinkResolver.resolve(url: URL(string: "https://example.com"), location: nil, notes: "no links") == nil)
    }
}

// MARK: - Interpreting the day

struct CalendarDayTests {
    @Test func currentNextAndFeatured() {
        let day = CalendarDay(events: [event("Standup", startsIn: -120), event("Review", startsIn: -10, lasting: 30),
                                       event("1:1", startsIn: 45), event("Holiday", startsIn: -720, lasting: 1_440, allDay: true)],
                              now: noon)
        #expect(day.current?.title == "Review")
        #expect(day.next?.title == "1:1")
        #expect(day.featured?.title == "Review")       // an ongoing meeting beats the next one
        #expect(day.allDay.map(\.title) == ["Holiday"]) // all-day events never become "next"
    }

    @Test func soonCoversTheTenMinutesBeforeAndFiveAfterTheStart() {
        #expect(CalendarDay(events: [event("A", startsIn: 4)], now: noon).soon()?.title == "A")
        #expect(CalendarDay(events: [event("A", startsIn: 11)], now: noon).soon() == nil)
        #expect(CalendarDay(events: [event("A", startsIn: -3)], now: noon).soon()?.title == "A")
        #expect(CalendarDay(events: [event("A", startsIn: -6)], now: noon).soon() == nil)
        #expect(CalendarDay(events: [event("Lunch", startsIn: 4, allDay: true)], now: noon).soon() == nil)
    }

    @Test func theNextBoundaryIncludesTheSoonWindow() {
        let day = CalendarDay(events: [event("A", startsIn: 30)], now: noon)
        #expect(day.nextBoundary() == noon.addingTimeInterval(20 * 60)) // when "in 10 min" should appear
    }

    @Test func countdownText() {
        #expect(CalendarDay.countdown(to: noon.addingTimeInterval(4 * 60), from: noon) == "in 4 min")
        #expect(CalendarDay.countdown(to: noon.addingTimeInterval(80 * 60), from: noon) == "in 1 h 20 min")
        #expect(CalendarDay.countdown(to: noon.addingTimeInterval(120 * 60), from: noon) == "in 2 h")
        #expect(CalendarDay.countdown(to: noon.addingTimeInterval(-60), from: noon) == "now")
        #expect(CalendarDay.initials("Ayşe Yılmaz") == "AY")
        #expect(CalendarDay.initials("") == "?")
    }
}

// MARK: - The module

private actor FakeCalendar: CalendarSource {
    var current: CalendarAccess
    var afterRequest: CalendarAccess
    var stored: [CalendarEvent]
    private(set) var requests = 0
    private(set) var fetches = 0

    init(access: CalendarAccess, afterRequest: CalendarAccess = .authorized, events: [CalendarEvent] = []) {
        current = access
        self.afterRequest = afterRequest
        stored = events
    }

    func set(access: CalendarAccess) { current = access }
    func set(events: [CalendarEvent]) { stored = events }
    func access() -> CalendarAccess { current }
    func requestAccess() -> CalendarAccess {
        requests += 1
        if current == .notDetermined { current = afterRequest }
        return current
    }
    func calendars() -> [CalendarInfo] {
        Set(stored.map(\.calendarID)).sorted().map { CalendarInfo(id: $0, title: $0, sourceTitle: "Google", color: .fallback) }
    }
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        fetches += 1
        return stored.filter { $0.start < end && $0.end > start }
    }
}

private actor RecordingReminders: ReminderScheduler {
    private(set) var scheduled: [[MeetingReminder]] = []
    private(set) var authorizations = 0
    func authorize() -> Bool { authorizations += 1; return true }
    func replaceAll(_ reminders: [MeetingReminder]) { scheduled.append(reminders) }
}

@MainActor
private func makeModule(_ source: FakeCalendar, reminders: RecordingReminders = RecordingReminders())
    -> (CalendarModule, UserDefaults, RecordingReminders) {
    let suite = "orilio-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (CalendarModule(source: source, reminders: reminders, defaults: defaults, now: { noon }), defaults, reminders)
}

@MainActor
struct CalendarModuleTests {
    @Test func offByDefaultAndNeverPromptsAtLaunch() async {
        let source = FakeCalendar(access: .notDetermined)
        let (module, _, _) = makeModule(source)
        module.start()
        await module.reload()
        #expect(module.status == .off)
        #expect(await source.requests == 0)
        #expect(await source.fetches == 0)
    }

    @Test func turningItOnAsksOnceAndShowsToday() async {
        let source = FakeCalendar(access: .notDetermined, events: [event("Design review", startsIn: 13, link: "https://meet.google.com/abc-defg-hij")])
        let (module, _, _) = makeModule(source)
        await module.enable()
        #expect(await source.requests == 1)
        #expect(module.status == .ready)
        #expect(module.day.next?.title == "Design review")
        #expect(module.day.next?.meeting?.provider == .googleMeet)
        await module.enable() // already decided: no second prompt
        #expect(await source.requests == 1)
    }

    @Test func deniedAndRevokedAccessShowTheDeniedState() async {
        let denied = FakeCalendar(access: .notDetermined, afterRequest: .denied)
        let (refused, _, _) = makeModule(denied)
        await refused.enable()
        #expect(refused.status == .denied)

        let source = FakeCalendar(access: .authorized, events: [event("A", startsIn: 5)])
        let (module, _, _) = makeModule(source)
        await module.enable()
        #expect(module.day.events.count == 1)
        await source.set(access: .denied) // revoked in System Settings
        await module.reload()
        #expect(module.status == .denied)
        #expect(module.day.events.isEmpty) // nothing stale stays on screen

        let restricted = FakeCalendar(access: .restricted)
        let (policy, _, _) = makeModule(restricted)
        await policy.enable()
        #expect(policy.status == .restricted)
    }

    @Test func emptyCalendarsAndHiddenCalendars() async {
        let source = FakeCalendar(access: .authorized)
        let (module, _, _) = makeModule(source)
        await module.enable()
        #expect(module.status == .ready)
        #expect(module.day.events.isEmpty)
        #expect(module.day.featured == nil)

        await source.set(events: [event("Work", startsIn: 20, calendar: "work"), event("Gym", startsIn: 60, calendar: "personal")])
        await module.reload()
        #expect(Set(module.calendars.map(\.id)) == ["work", "personal"])
        module.setCalendar("personal", visible: false)
        await module.reload()
        #expect(module.day.events.map(\.title) == ["Work"])
    }

    @Test func calendarChangesAreReadOnReload() async {
        let source = FakeCalendar(access: .authorized, events: [event("A", startsIn: 30)])
        let (module, _, _) = makeModule(source)
        await module.enable()
        await source.set(events: [event("A", startsIn: 30), event("B", startsIn: 90)])
        await module.reload() // what an EKEventStoreChanged notification triggers
        #expect(module.day.events.map(\.title) == ["A", "B"])
    }

    @Test func remindersAreReplacedNotDuplicatedAndOffMeansNone() async {
        let source = FakeCalendar(access: .authorized, events: [event("A", startsIn: 30), event("Past", startsIn: -60)])
        let (module, _, reminders) = makeModule(source)
        await module.enable()
        #expect(await reminders.scheduled.last == []) // off by default
        #expect(await reminders.authorizations == 0)  // and notifications were never asked for

        await module.setReminderLead(5)
        await module.reload()
        let latest = await reminders.scheduled.last ?? []
        #expect(latest.map(\.title) == ["A"]) // one per upcoming event, past events skipped
        #expect(latest.first?.fireDate == noon.addingTimeInterval(25 * 60))
        #expect(Set(latest.map(\.id)).count == latest.count)
        #expect(await reminders.authorizations == 1)

        module.disable()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await reminders.scheduled.last == []) // turning Calendar off removes pending reminders
    }

    @Test func theCollapsedIslandWidensForAMeetingSoon() async {
        let source = FakeCalendar(access: .authorized, events: [event("Design review", startsIn: 4)])
        let (module, _, _) = makeModule(source)
        await module.enable()
        let island = IslandModel(calendar: module)
        #expect(island.meetingSoon?.title == "Design review")
        #expect(island.liveCollapsedWidth == IslandGeometry.meetingWidth)

        await source.set(events: [event("Later", startsIn: 45)])
        await module.reload()
        #expect(island.meetingSoon == nil)
        #expect(island.liveCollapsedWidth == nil)
    }
}

import AppKit
import SwiftUI

/// Renders the Calendar panel with the design's sample day, for a side-by-side visual check:
/// ORILIO_RENDER=/path/out.png swift test --filter CalendarRender
@MainActor
struct CalendarRender {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_RENDER"] != nil))
    func renderTheDesignDay() async throws {
        var parts = DateComponents(year: 2026, month: 10, day: 28, hour: 14, minute: 32)
        parts.calendar = Calendar.current
        let now = parts.date!
        func at(_ h: Int, _ m: Int, _ minutes: Double, _ title: String, _ source: String, _ color: CalendarColor,
                link: String? = nil, people: [String] = []) -> CalendarEvent {
            var c = parts; c.hour = h; c.minute = m
            let start = c.date!
            return CalendarEvent(id: title, eventIdentifier: title, title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                                 isAllDay: false, calendarID: source, calendarTitle: source, sourceTitle: source, color: color,
                                 attendeeNames: people, meeting: link.flatMap(URL.init(string:)).flatMap(MeetingLinkResolver.validate))
        }
        let blue = CalendarColor(red: 0.43, green: 0.66, blue: 1), purple = CalendarColor(red: 0.79, green: 0.64, blue: 1)
        let coral = CalendarColor(red: 1, green: 0.54, blue: 0.48)
        let events = [
            at(9, 30, 15, "Standup", "Google", blue),
            at(11, 0, 45, "Infra sync", "Outlook", purple, link: "https://teams.microsoft.com/l/meetup-join/x"),
            at(14, 45, 30, "Design review", "Google", blue, link: "https://meet.google.com/abc-defg-hij",
               people: ["Enbiya Goral", "Ayşe Yılmaz", "Mert Kaya", "Deniz Ak", "Cem Er"]),
            at(16, 30, 30, "1:1 with Mert", "Outlook", purple, link: "https://teams.microsoft.com/l/meetup-join/y"),
            at(18, 0, 90, "Climbing", "iCloud", coral),
        ]
        let source = FakeCalendar(access: .authorized, events: events)
        let suite = "orilio-render-\(UUID().uuidString)"
        let module = CalendarModule(source: source, reminders: RecordingReminders(), defaults: UserDefaults(suiteName: suite)!, now: { now })
        await module.enable()

        let view = CalendarPanel(module: module, fixedNow: now)
            .padding(.top, 10).padding(.horizontal, 20).padding(.bottom, 20)
            .frame(width: 700, height: 266)
            .background(.black)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_RENDER"]!))
    }
}
