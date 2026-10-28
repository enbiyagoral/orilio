// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func event(_ title: String, startsIn minutes: Double, allDay: Bool = false) -> CalendarEvent {
    let start = now.addingTimeInterval(minutes * 60)
    return CalendarEvent(id: title, eventIdentifier: nil, title: title, start: start, end: start.addingTimeInterval(1_800),
                         isAllDay: allDay, calendarID: "c", calendarTitle: "Work", sourceTitle: "iCloud", color: .fallback,
                         attendeeNames: [], meeting: nil)
}

struct CalendarCardStateTests {
    private func resolve(_ status: CalendarModule.Status, declined: Bool = false, calendars: Int = 1,
                         events: [CalendarEvent] = [], later: CalendarEvent? = nil, offline: Bool = false) -> CalendarCardState {
        CalendarCardState.resolve(status: status, declined: declined, calendarCount: calendars,
                                  day: CalendarDay(events: events, now: now), nextLater: later, offline: offline)
    }

    @Test func access() {
        #expect(resolve(.off) == .ask) // first open: the in-island card before any prompt
        #expect(resolve(.off, declined: true) == .declined) // Not now: access off, Turn on
        #expect(resolve(.needsAccess) == .ask)
        #expect(resolve(.denied) == .denied) // also revoked in System Settings
        #expect(resolve(.restricted) == .restricted)
    }

    @Test func data() {
        #expect(resolve(.ready, calendars: 0) == .noCalendars)
        let tomorrow = event("Standup", startsIn: 20 * 60)
        #expect(resolve(.ready, events: [event("Done earlier", startsIn: -120)], later: tomorrow) == .clearRestOfDay(next: tomorrow))
        #expect(resolve(.ready) == .clearRestOfDay(next: nil))
        #expect(resolve(.ready, events: [event("Design review", startsIn: 30)]) == .events(offline: false))
        #expect(resolve(.ready, events: [event("Design review", startsIn: 30)], offline: true) == .events(offline: true))
    }
}

struct NowPlayingCardStateTests {
    private func resolve(app: String? = "spotify", access: ControlAccess? = .undetermined, declined: Bool = false,
                         revoked: [String] = [], spotify: Bool = true, music: Bool = true, session: Bool = true) -> NowPlayingCardState {
        NowPlayingCardState.resolve(sessionApp: app, access: access, declined: declined, revokedApps: revoked,
                                    spotifyInstalled: spotify, musicInstalled: music, hasSession: session)
    }

    @Test func askedPerAppTheFirstTimeItPlays() {
        #expect(resolve() == .session(ask: "spotify"))
        #expect(resolve(declined: true) == .session(ask: nil)) // Not now: playback info only, no nagging
        #expect(resolve(access: .granted) == .session(ask: nil))
        #expect(resolve(access: .denied) == .session(ask: nil)) // denied shows "Can't control" inline
        #expect(resolve(app: nil, access: nil) == .session(ask: nil)) // a browser tab never asks
    }

    @Test func nothingPlaying() {
        #expect(resolve(session: false) == .nothingPlaying(spotify: true, music: true))
        #expect(resolve(spotify: false, session: false) == .spotifyMissing)
        #expect(resolve(revoked: ["Spotify"], session: false) == .revoked(app: "Spotify"))
    }
}

struct ClipboardCardStateTests {
    @Test func states() {
        func r(_ s: ClipboardModule.Status, declined: Bool = false, empty: Bool = false, privacy: Bool = false) -> ClipboardCardState {
            ClipboardCardState.resolve(status: s, declined: declined, isEmpty: empty, privacyPaused: privacy)
        }
        #expect(r(.off) == .ask)
        #expect(r(.off, declined: true) == .off)
        #expect(r(.blocked) == .blocked)
        #expect(r(.on, empty: true) == .empty)
        #expect(r(.on, privacy: true) == .privacyPaused)
        #expect(r(.paused) == .history)
        #expect(r(.on) == .history)
    }
}

struct SmallModuleStateTests {
    @Test func notesAllDone() {
        let t = Date.now
        func task(_ done: Bool) -> TaskItem { TaskItem(id: UUID(), title: "x", done: done, createdAt: t) }
        #expect(!NotesCardState.allDone([]))
        #expect(NotesCardState.allDone([task(true), task(true)]))
        #expect(!NotesCardState.allDone([task(true), task(false)]))
    }

    @Test func shelf() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "orilio-state-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        var item = try #require(ShelfItem.load(file, origin: .reference))
        #expect(ShelfCardState.resolve([], pending: 0) == .empty)
        #expect(ShelfCardState.resolve([], pending: 1) == .files)
        #expect(ShelfCardState.resolve([item], pending: 0) == .files)
        item.isAvailable = false
        #expect(ShelfCardState.resolve([item], pending: 0) == .missing(item.id))
    }

    @Test func focusEndedWhileAsleep() {
        #expect(FocusCardState.endedWhileAsleep(deadline: now, noticedAt: now.addingTimeInterval(3_600)))
        #expect(!FocusCardState.endedWhileAsleep(deadline: now, noticedAt: now.addingTimeInterval(0.5)))
    }
}

/// A calendar that counts how often it asks macOS.
private actor CountingCalendar: CalendarSource {
    private(set) var requests = 0
    func access() -> CalendarAccess { .notDetermined }
    func requestAccess() -> CalendarAccess { requests += 1; return .denied }
    func calendars() -> [CalendarInfo] { [] }
    func events(from start: Date, to end: Date) -> [CalendarEvent] { [] }
}

@MainActor
struct NotNowTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "orilio.notnow.\(UUID().uuidString)")! }

    @Test func calendarNotNowNeverPrompts() async {
        let source = CountingCalendar()
        let module = CalendarModule(source: source, reminders: NoReminders(), defaults: defaults())
        module.decline()
        await module.reload()
        #expect(await source.requests == 0)
        #expect(module.status == .off)
        #expect(module.declined)
        await module.enable() // Turn on from the access-off card: now macOS may ask
        #expect(await source.requests == 1)
        #expect(!module.declined)
    }

    @Test func clipboardNotNowStaysOff() async {
        let d = defaults()
        let module = ClipboardModule(store: ClipboardStore(directory: FileManager.default.temporaryDirectory.appending(path: "orilio-nn-\(UUID().uuidString)")),
                                     defaults: d)
        module.decline()
        #expect(module.status == .off)
        #expect(ClipboardCardState.resolve(status: module.status, declined: module.declined, isEmpty: true, privacyPaused: false) == .off)
    }

    @Test func mirrorNotNowNeverAsks() {
        var s = MirrorSnapshot()
        _ = MirrorReducer.reduce(&s, .shown(.notDetermined))
        #expect(MirrorReducer.reduce(&s, .hidden).isEmpty) // Not now closes: no requestAccess effect
    }

    @Test func focusSessionThatEndedAsleepIsReported() {
        var clock = Date.now.addingTimeInterval(365 * 86_400)
        let focus = FocusModule(defaults: defaults(), notifier: Mute(), now: { clock })
        focus.begin()
        clock.addTimeInterval(25 * 60 + 600) // the Mac slept through the deadline
        focus.check()
        #expect(focus.endedWhileAsleep != nil)
        focus.begin()
        #expect(focus.endedWhileAsleep == nil)
    }
}

private struct Mute: FocusNotifier {
    func authorize() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func schedule(at date: Date, minutes: Int) async {}
    func cancel() async {}
}

@MainActor
struct LegacyDefaultsTests {
    @Test func settingsComeAlongOnceWithoutOverwriting() {
        let old = "orilio.legacy.\(UUID().uuidString)", new = "orilio.new.\(UUID().uuidString)"
        let oldDefaults = UserDefaults(suiteName: old)!
        oldDefaults.set("all", forKey: "displays.placement")
        oldDefaults.set(true, forKey: "calendar.enabled")
        let defaults = UserDefaults(suiteName: new)!
        defaults.set("pointer", forKey: "displays.placement") // already set under the new identifier
        LegacyDefaults.migrate(from: old, into: defaults)
        #expect(defaults.bool(forKey: "calendar.enabled"))
        #expect(defaults.string(forKey: "displays.placement") == "pointer")
        oldDefaults.set(false, forKey: "calendar.enabled")
        defaults.removeObject(forKey: "calendar.enabled")
        LegacyDefaults.migrate(from: old, into: defaults) // only once
        #expect(defaults.object(forKey: "calendar.enabled") == nil)
    }
}
