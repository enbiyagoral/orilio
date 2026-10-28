// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let all = Set(IslandTab.allCases)
private let every = Set(CollapsedIndicator.allCases)

private func meeting(startsIn minutes: Double, title: String = "Design review", link: Bool = true) -> CalendarEvent {
    let start = now.addingTimeInterval(minutes * 60)
    return CalendarEvent(id: "m\(minutes)", eventIdentifier: nil, title: title, start: start, end: start.addingTimeInterval(1_800),
                         isAllDay: false, calendarID: "work", calendarTitle: "Work", sourceTitle: "Google", color: .fallback,
                         attendeeNames: [], meeting: link ? MeetingLinkResolver.validate(URL(string: "https://meet.google.com/abc-defg-hij")!) : nil)
}

private let song = MediaSessionSnapshot(sourceID: "spotify", providerID: "spotify", sourceName: "Spotify", title: "Harbor Lights",
                                        artist: "Low Tide Radio", album: nil, artworkURL: nil, state: .playing, duration: 200,
                                        position: 10, positionDate: now, capabilities: [], updatedAt: now)
private let copied = Transient(title: "Copied", detail: "kubectl rollout restart deploy/api", monospaced: true, module: .clipboard)

private func layout(meeting: CalendarEvent? = nil, focus: Bool = false, transient: Transient? = nil, music: Bool = false,
                    visible: Set<IslandTab> = all, indicators: Set<CollapsedIndicator> = every) -> EarLayout {
    LiveActivityResolver.layout(meeting: meeting, focus: focus ? .running : nil, transient: transient, nowPlaying: music ? song : nil,
                                visible: visible, indicators: indicators)
}

struct LiveActivityResolverTests {
    @Test func meetingBeatsFocus() {
        let result = layout(meeting: meeting(startsIn: 4), focus: true, music: true)
        #expect(result.leading?.kind == .meeting && result.trailing?.kind == .meeting)
        #expect(result.primary?.module == .calendar)
    }

    @Test func focusAndMusicShareTheEars() {
        let result = layout(focus: true, music: true)
        #expect(result.leading?.kind == .focus)
        #expect(result.trailing?.kind == .nowPlaying)
        #expect(result.primary?.kind == .focus) // hover opens Focus
        #expect(result.activity(at: .trailing)?.module == .music) // clicking the right ear opens Music
    }

    @Test func focusAloneLeavesTheTrailingEarEmpty() {
        let result = layout(focus: true)
        #expect(result.leading?.kind == .focus)
        #expect(result.trailing == nil)
        #expect(result.activity(at: .trailing)?.module == .focus) // the click still lands on the live module
    }

    @Test func transientOverridesFocusAndMusicButNeverAMeeting() {
        let over = layout(focus: true, transient: copied, music: true)
        #expect(over.leading?.kind == .transient && over.trailing?.kind == .transient)
        let meetingWins = layout(meeting: meeting(startsIn: 4), transient: copied)
        #expect(meetingWins.leading?.kind == .meeting)
    }

    @Test func musicAloneTakesBothEars() {
        let result = layout(music: true)
        #expect(result.leading?.kind == .nowPlaying && result.trailing?.kind == .nowPlaying)
    }

    @Test func hiddenModulesNeverShowEvenWhenActive() {
        #expect(layout(meeting: meeting(startsIn: 4), visible: all.subtracting([.calendar])).isIdle)
        #expect(layout(focus: true, visible: all.subtracting([.focus])).isIdle)
        #expect(layout(transient: copied, visible: all.subtracting([.clipboard])).isIdle)
        #expect(layout(music: true, visible: all.subtracting([.music])).isIdle)
        #expect(layout(focus: true, music: true, indicators: [.music]).leading?.kind == .nowPlaying)
    }

    @Test func idleHasNoActivity() {
        let result = layout()
        #expect(result.isIdle)
        #expect(result.primary == nil)
        #expect(result.collapsedWidth(notch: 185, pill: 220, now: now) == nil) // the notch alone
    }
}

struct EarGeometryTests {
    @Test func widthIsTheNotchPlusTwoEqualEars() {
        let result = layout(music: true)
        let ear = result.earWidth(now: now)
        #expect(result.collapsedWidth(notch: 185, pill: 220, now: now) == 185 + 2 * ear)
        #expect(result.collapsedWidth(notch: 200, pill: 220, now: now) == 200 + 2 * ear) // read from the screen, not fixed
    }

    @Test func earsComeFromTheContentAndAreClamped() {
        let music = layout(music: true).earWidth(now: now)
        let meetingEar = layout(meeting: meeting(startsIn: 4)).earWidth(now: now)
        #expect(meetingEar > music)
        let long = layout(meeting: meeting(startsIn: 4, title: String(repeating: "Quarterly planning ", count: 6))).earWidth(now: now)
        #expect(long == EarLayout.maxEar)
    }

    @Test func atStartTheTrailingEarIsJoin() {
        let started = meeting(startsIn: 0)
        #expect(MeetingEar.showsJoin(started, now: now))
        #expect(MeetingEar.title(started, now: now) == "Design review · now")
        #expect(!MeetingEar.showsJoin(meeting(startsIn: 4), now: now))
        #expect(!MeetingEar.showsJoin(meeting(startsIn: 0, link: false), now: now)) // no link, no Join
    }

    @Test func withoutANotchThePillKeepsItsMinimumWidth() {
        #expect(layout(music: true).collapsedWidth(notch: 0, pill: 220, now: now) == 220)
    }
}

@MainActor
struct LiveActivityCoordinatorTests {
    @Test func transientExpiresAndNeverQueues() async throws {
        let live = LiveActivityCoordinator(transientDuration: .milliseconds(150))
        let first = Transient(title: "Copied", module: .clipboard)
        let second = Transient(symbol: "photo", title: "Screenshot saved", module: .shelf)
        live.flash(first)
        try await Task.sleep(for: .milliseconds(100))
        live.flash(second) // replaces the first one; its timer starts over
        #expect(live.transient == second)
        try await Task.sleep(for: .milliseconds(100))
        #expect(live.transient == second) // the first one's expiry didn't end the second
        try await Task.sleep(for: .milliseconds(150))
        #expect(live.transient == nil) // and nothing was waiting behind it
    }

    @Test func islandOpensToTheLiveModuleOrTheClickedEar() async {
        let defaults = UserDefaults(suiteName: "orilio.live.\(UUID().uuidString)")!
        let focus = FocusModule(defaults: defaults, notifier: Quiet())
        let island = IslandModel(focus: focus, modules: ModuleSettings(defaults: defaults))
        focus.begin()
        island.tapEar(.leading)
        #expect(island.tab == .focus)
        island.dismiss()
        focus.reset()
        island.live.flash(Transient(title: "Copied", module: .clipboard))
        island.tapEar(.trailing)
        #expect(island.tab == .clipboard) // a confirmation opens its own module
    }
}

private struct Quiet: FocusNotifier {
    func authorize() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func schedule(at date: Date, minutes: Int) async {}
    func cancel() async {}
}

private extension CalendarEvent {
    func with(start: Date) -> CalendarEvent {
        CalendarEvent(id: id, eventIdentifier: eventIdentifier, title: title, start: start, end: start.addingTimeInterval(1_800),
                      isAllDay: isAllDay, calendarID: calendarID, calendarTitle: calendarTitle, sourceTitle: sourceTitle,
                      color: color, attendeeNames: attendeeNames, meeting: meeting)
    }
}
