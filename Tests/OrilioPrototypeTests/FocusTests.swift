// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

private actor RecordingNotifier: FocusNotifier {
    var granted: Bool
    private(set) var asked = 0
    private(set) var pending: Date?
    private(set) var scheduled = 0

    init(granted: Bool) { self.granted = granted }

    func authorize() -> Bool { asked += 1; return granted }
    func isAuthorized() -> Bool { granted }
    func schedule(at date: Date, minutes: Int) { pending = date; scheduled += 1 }
    func cancel() { pending = nil }
    func revoke() { granted = false }
}

@MainActor
private final class Clock {
    // A year ahead: the module's real Timer, armed for the fake deadline, never fires mid-test.
    var now = Date.now.addingTimeInterval(365 * 86_400)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

@MainActor
private func makeFocus(_ defaults: UserDefaults = UserDefaults(suiteName: "orilio.focus.\(UUID().uuidString)")!,
                       clock: Clock = Clock(), granted: Bool = true) -> (FocusModule, Clock, RecordingNotifier, UserDefaults) {
    let notifier = RecordingNotifier(granted: granted)
    let focus = FocusModule(defaults: defaults, notifier: notifier, now: { clock.now })
    return (focus, clock, notifier, defaults)
}

struct FocusSessionTests {
    @Test func deadlineModel() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let running = FocusSession.start(1_500, at: t)
        #expect(running.remaining(at: t.addingTimeInterval(600)) == 900)
        #expect(running.remaining(at: t.addingTimeInterval(9_999)) == 0)
        let paused = running.paused(at: t.addingTimeInterval(600))
        #expect(paused.remaining(at: t.addingTimeInterval(5_000)) == 900) // a paused session doesn't move
        #expect(paused.resumed(at: t.addingTimeInterval(5_000)).endsAt == t.addingTimeInterval(5_900))
        #expect(running.fraction(at: t.addingTimeInterval(750)) == 0.5)
    }

    @Test func text() {
        #expect(FocusSession.text(1_500) == "25:00")
        #expect(FocusSession.text(245) == "4:05")
        #expect(FocusSession.text(5_400) == "1:30:00")
        #expect(FocusSession.text(0.2) == "0:01") // rounds up: "0:00" only when done
    }
}

@MainActor
struct FocusModuleTests {
    @Test func startPauseResumeReset() async {
        let (focus, clock, _, _) = makeFocus()
        #expect(focus.stateText == "ready")
        focus.toggle()
        #expect(focus.isRunning)
        clock.advance(300)
        focus.toggle()
        #expect(focus.stateText == "paused")
        clock.advance(10_000)
        #expect(focus.remaining(at: clock.now) == 1_200)
        focus.toggle()
        #expect(focus.isRunning)
        focus.reset()
        #expect(!focus.isActive)
        #expect(focus.completedToday == 0)
    }

    @Test func completesExactlyOnce() async {
        let (focus, clock, _, _) = makeFocus()
        focus.begin()
        clock.advance(1_500)
        focus.check()
        focus.check()
        focus.pause()
        focus.resume()
        focus.check()
        #expect(focus.completedToday == 1)
        #expect(!focus.isActive)
    }

    @Test func rapidPauseResumeNeverCompletesEarlyOrTwice() async {
        let (focus, clock, notifier, _) = makeFocus()
        await focus.setNotify(true)
        focus.begin()
        for _ in 0..<50 {
            clock.advance(10)
            focus.pause()
            focus.resume()
        }
        focus.check()
        #expect(focus.isRunning) // 500 s of 1,500 used
        await focus.settle()
        #expect(await notifier.pending == clock.now.addingTimeInterval(1_000))
        clock.advance(1_000)
        focus.pause() // arrives after the deadline: completes instead
        focus.check()
        #expect(focus.completedToday == 1)
    }

    @Test func pauseAndResetCancelTheNotification() async {
        let (focus, _, notifier, _) = makeFocus()
        await focus.setNotify(true)
        focus.begin()
        await focus.settle()
        #expect(await notifier.pending != nil)
        focus.pause()
        await focus.settle()
        #expect(await notifier.pending == nil)
        focus.resume()
        focus.reset()
        await focus.settle()
        #expect(await notifier.pending == nil)
    }

    @Test func notificationsAreAskedForOnlyWhenTurnedOn() async {
        let (focus, _, notifier, _) = makeFocus()
        focus.begin()
        await focus.settle()
        #expect(await notifier.asked == 0)
        #expect(await notifier.scheduled == 0)
    }

    @Test func worksWithNotificationsDenied() async {
        let (focus, clock, notifier, _) = makeFocus(granted: false)
        await focus.setNotify(true)
        #expect(!focus.notify)
        #expect(focus.notificationsDenied)
        focus.begin()
        clock.advance(1_500)
        focus.check()
        #expect(focus.completedToday == 1)
        #expect(await notifier.scheduled == 0)
    }

    @Test func revokedLaterStillRuns() async {
        let (focus, _, notifier, _) = makeFocus()
        await focus.setNotify(true)
        await notifier.revoke()
        focus.begin()
        await focus.settle()
        #expect(focus.notificationsDenied)
        #expect(focus.isRunning)
    }

    @Test func sleepCountsAsTimePassing() async {
        let (focus, clock, _, _) = makeFocus()
        focus.begin()
        clock.advance(3_600) // asleep past the deadline; the wake handler calls check()
        focus.check()
        #expect(focus.completedToday == 1)
    }

    @Test func restartRestoresRunningAndPausedSessions() async {
        let (focus, clock, _, defaults) = makeFocus()
        focus.begin()
        clock.advance(600)
        let (again, _, _, _) = makeFocus(defaults, clock: clock)
        again.start()
        #expect(again.isRunning)
        #expect(again.remaining(at: clock.now) == 900)

        again.pause()
        clock.advance(10_000)
        let (third, _, _, _) = makeFocus(defaults, clock: clock)
        third.start()
        #expect(third.stateText == "paused")
        #expect(third.remaining(at: clock.now) == 900)
    }

    @Test func sessionThatEndedWhileQuitCountsOnceOnLaunch() async {
        let (focus, clock, _, defaults) = makeFocus()
        focus.begin()
        clock.advance(5_000)
        let (again, _, notifier, _) = makeFocus(defaults, clock: clock)
        again.start()
        #expect(!again.isActive)
        #expect(again.completedToday == 1)
        #expect(await notifier.scheduled == 0)
        let (third, _, _, _) = makeFocus(defaults, clock: clock)
        third.start()
        #expect(third.completedToday == 1)
    }

    @Test func dailyCountResetsOnANewDay() async {
        let (focus, clock, _, _) = makeFocus()
        focus.begin(); clock.advance(1_500); focus.check()
        focus.begin(); clock.advance(1_500); focus.check()
        #expect(focus.completedToday == 2)
        clock.advance(86_400)
        focus.refreshDay()
        #expect(focus.completedToday == 0)
    }

    @Test func durationsAndPresets() async {
        let (focus, _, _, _) = makeFocus()
        focus.setMinutes(50)
        #expect(focus.remaining(at: .now) == 3_000)
        focus.setMinutes(0)
        #expect(focus.minutes == 1)
        focus.setMinutes(1_000)
        #expect(focus.minutes == 240)
        #expect([1, 4, 5, 7, 10].map { FocusModule.step($0, up: true) } == [5, 5, 10, 10, 15])
        #expect([1, 5, 7, 10, 240].map { FocusModule.step($0, up: false) } == [1, 1, 5, 5, 235])
        focus.begin()
        focus.setMinutes(25) // ignored during a session
        #expect(focus.minutes == 240)
    }

    @Test func collapsedIslandShowsARunningSession() async {
        let (focus, _, _, _) = makeFocus()
        let island = IslandModel(focus: focus)
        #expect(island.liveCollapsedWidth == nil)
        focus.begin()
        #expect(island.earLayout.leading?.kind == .focus)
        #expect(island.liveCollapsedWidth != nil)
    }
}
