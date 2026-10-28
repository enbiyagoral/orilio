import Foundation
import Testing
@testable import OrilioPrototype

private actor Quiet: FocusNotifier {
    func authorize() -> Bool { true }
    func isAuthorized() -> Bool { false }
    func schedule(at date: Date, minutes: Int) {}
    func cancel() {}
}

@MainActor
private final class Clock {
    var now = Date.now.addingTimeInterval(365 * 86_400) // the module's real Timer never fires mid-test
}

@MainActor
private func focus() -> (FocusModule, Clock) {
    let clock = Clock()
    let module = FocusModule(defaults: UserDefaults(suiteName: "orilio.focusend.\(UUID().uuidString)")!, notifier: Quiet(),
                             now: { clock.now })
    return (module, clock)
}

struct IslandKeyRouterTests {
    private func key(_ code: UInt16, _ chars: String = "", command: Bool = false, shift: Bool = false, control: Bool = false) -> KeyPress {
        KeyPress(keyCode: code, characters: chars, command: command, shift: shift, control: control)
    }

    @Test func everywhere() {
        for tab in IslandTab.allCases {
            #expect(IslandKeyRouter.route(key(18, command: true), tab: tab) == .module(0)) // ⌘1
            #expect(IslandKeyRouter.route(key(22, command: true), tab: tab) == .module(5)) // ⌘6
            #expect(IslandKeyRouter.route(key(48, control: true), tab: tab) == .adjacentModule(1))
            #expect(IslandKeyRouter.route(key(48, shift: true, control: true), tab: tab) == .adjacentModule(-1))
            #expect(IslandKeyRouter.route(key(35, command: true, shift: true), tab: tab) == .togglePin) // ⌘⇧P
            #expect(IslandKeyRouter.route(key(43, command: true), tab: tab) == .settings)
            #expect(IslandKeyRouter.route(key(13, command: true), tab: tab) == .closeAndUnpin)
            #expect(IslandKeyRouter.route(key(53), tab: tab) == .close)
            #expect(IslandKeyRouter.route(key(36), tab: tab) == .primary)
        }
    }

    @Test func perModule() {
        // ↑↓ only move in lists; a Shelf row is five tiles, ←→ step one.
        #expect(IslandKeyRouter.route(key(125), tab: .clipboard) == .move(1))
        #expect(IslandKeyRouter.route(key(125), tab: .notes) == .move(1))
        #expect(IslandKeyRouter.route(key(125), tab: .shelf) == .move(5))
        #expect(IslandKeyRouter.route(key(124), tab: .shelf) == .move(1))
        #expect(IslandKeyRouter.route(key(125), tab: .calendar) == nil)
        // Space previews on the Shelf only; ⌘P and ⌘F are the clipboard's; ⌘⌫ deletes in lists.
        #expect(IslandKeyRouter.route(key(49), tab: .shelf) == .preview)
        #expect(IslandKeyRouter.route(key(49), tab: .music) == nil)
        #expect(IslandKeyRouter.route(key(35, command: true), tab: .clipboard) == .pinItem)
        #expect(IslandKeyRouter.route(key(35, command: true), tab: .shelf) == nil)
        #expect(IslandKeyRouter.route(key(3, command: true), tab: .clipboard) == .search)
        #expect(IslandKeyRouter.route(key(51, command: true), tab: .notes) == .deleteItem)
        #expect(IslandKeyRouter.route(key(51, command: true), tab: .focus) == nil)
        // A letter in the clipboard list jumps into its search; elsewhere it's nothing.
        #expect(IslandKeyRouter.route(key(0, "a"), tab: .clipboard) == .type("a"))
        #expect(IslandKeyRouter.route(key(0, "a"), tab: .calendar) == nil)
    }

    @Test func whileTyping() {
        // In the search field: ↑↓ and ⏎ still drive the list; letters are the field's.
        #expect(IslandKeyRouter.route(key(125), tab: .clipboard, editing: .search) == .move(1))
        #expect(IslandKeyRouter.route(key(36), tab: .clipboard, editing: .search) == .primary)
        #expect(IslandKeyRouter.route(key(0, "a"), tab: .clipboard, editing: .search) == nil)
        // In a note or a task field, only ⌘ shortcuts and esc; ⌘⌫ deletes text there.
        #expect(IslandKeyRouter.route(key(125), tab: .notes, editing: .text) == nil)
        #expect(IslandKeyRouter.route(key(36), tab: .notes, editing: .text) == nil)
        #expect(IslandKeyRouter.route(key(51, command: true), tab: .notes, editing: .text) == nil)
        #expect(IslandKeyRouter.route(key(19, command: true), tab: .notes, editing: .text) == .module(1))
        #expect(IslandKeyRouter.route(key(53), tab: .notes, editing: .text) == .close)
    }

    @Test func listCursorIsShared() {
        #expect(ListCursor.moved(nil, in: [1, 2, 3], by: 1) == 1)
        #expect(ListCursor.moved(nil, in: [1, 2, 3], by: -1) == 3)
        #expect(ListCursor.moved(2, in: [1, 2, 3], by: 1) == 3)
        #expect(ListCursor.moved(3, in: [1, 2, 3], by: 5) == 3) // held at the end
        #expect(ListCursor.moved(9, in: [1, 2, 3], by: 1) == 1) // a removed item starts over
        #expect(ListCursor.moved(1, in: [Int](), by: 1) == nil)
    }

    @Test func commandBadgesAfter400ms() {
        var hold = CommandHold()
        hold.changed(commandOnly: true, at: 10)
        #expect(!hold.showsBadges(at: 10.3))
        #expect(hold.showsBadges(at: 10.4))
        hold.changed(commandOnly: true, at: 10.5) // still held: the clock doesn't restart
        #expect(hold.showsBadges(at: 10.5))
        hold.changed(commandOnly: false, at: 11) // released, or ⌘⇧
        #expect(!hold.showsBadges(at: 12))
        hold.changed(commandOnly: true, at: 20)
        hold.cancel() // ⌘ plus a key is a shortcut, not a hold
        #expect(!hold.showsBadges(at: 21))
    }
}

@MainActor
struct FocusEndTests {
    @Test func sessionDoneWaitsForTheUserAndBreaksFollowTheCycle() {
        let (module, clock) = focus()
        module.setMinutes(25)
        module.begin()
        clock.now.addTimeInterval(25 * 60 + 0.5)
        module.check()
        #expect(module.finished == .session(number: 1, minutes: 25))
        #expect(!module.isActive && !module.isOnBreak) // nothing starts by itself
        #expect(FocusEarKind(module) == .done("Session done"))
        module.startBreak()
        #expect(module.breakSession?.duration == 300.0)
        #expect(FocusEarKind(module) == .onBreak)
        clock.now.addTimeInterval(5 * 60 + 0.5)
        module.check()
        #expect(module.finished == .breakOver(next: 2))
        module.doneForNow()
        #expect(FocusEarKind(module) == nil)
    }

    @Test func theFourthBreakIsLong() {
        let (module, clock) = focus()
        module.setMinutes(1)
        for _ in 0..<4 {
            module.keepGoing()
            clock.now.addTimeInterval(61)
            module.check()
        }
        #expect(module.finished == .session(number: 4, minutes: 1))
        module.startBreak()
        #expect(module.breakSession?.duration == 900.0)
        #expect(FocusModule.breakMinutes(after: 3) == 5 && FocusModule.breakMinutes(after: 8) == 15)
        #expect(FocusModule.cycleNumber(completed: 5) == 1)
    }

    @Test func aSessionThatEndedDuringSleepIsQuiet() {
        let (module, clock) = focus()
        module.setMinutes(25)
        module.begin()
        clock.now.addTimeInterval(25 * 60 + 40 * 60) // the lid was closed for most of it
        module.check()
        #expect(module.endedWhileAsleep != nil) // "Session ended at HH:MM"
        #expect(module.finished == nil) // no card, no auto-open, no chime
        #expect(module.completedToday == 1) // still counted, from the wall clock
    }

    @Test func autoOpenWaitsForFullscreenHideMeetingsAndOtherModules() {
        #expect(FocusEndPolicy.canOpen(fullscreen: nil, meetingShowing: false, islandOpenElsewhere: false))
        #expect(FocusEndPolicy.canOpen(fullscreen: .show, meetingShowing: false, islandOpenElsewhere: false))
        #expect(!FocusEndPolicy.canOpen(fullscreen: .hide, meetingShowing: false, islandOpenElsewhere: false))
        #expect(!FocusEndPolicy.canOpen(fullscreen: nil, meetingShowing: true, islandOpenElsewhere: false))
        #expect(!FocusEndPolicy.canOpen(fullscreen: nil, meetingShowing: false, islandOpenElsewhere: true))
    }

    @Test func theCardOpensTheIslandWithoutTakingTheKeyboard() {
        let island = IslandModel(focus: focus().0)
        island.isPointerBusy = { false }
        var focusAtPin: Bool?
        island.onWillChangeState = { [unowned island] state in if state == .pinned { focusAtPin = island.pinTakesFocus } }
        island.presentFocusEnd()
        #expect(island.state == .pinned && island.tab == .focus)
        #expect(focusAtPin == false)
        #expect(!island.keyboardOpened)
    }

    @Test func keyboardOpenShowsTheHintsAndAClickEndsThem() {
        let island = IslandModel(focus: focus().0)
        island.isPointerBusy = { false }
        island.openFromKeyboard()
        #expect(island.keyboardOpened)
        island.pointerUsed()
        #expect(!island.keyboardOpened)
        island.openFromKeyboard()
        #expect(island.handleKey(KeyPress(keyCode: 19, command: true), editing: .none)) // ⌘2
        #expect(island.tab == island.modules.visible[1])
        island.dismiss()
        #expect(!island.keyboardOpened)
    }
}
