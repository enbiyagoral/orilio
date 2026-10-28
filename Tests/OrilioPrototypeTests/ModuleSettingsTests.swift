import Foundation
import Testing
@testable import OrilioPrototype

@MainActor
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "orilio.modules.\(UUID().uuidString)")! }

private let meeting = CalendarEvent(id: "m", eventIdentifier: nil, title: "Design review", start: .now, end: .now.addingTimeInterval(1_800),
                                    isAllDay: false, calendarID: "work", calendarTitle: "Work", sourceTitle: "Google",
                                    color: .fallback, attendeeNames: [], meeting: nil)

struct CollapsedLiveTests {
    private let all = Set(IslandTab.allCases)
    private let every = Set(CollapsedIndicator.allCases)

    @Test func priorityIsMeetingThenFocusThenMusic() {
        #expect(CollapsedLive.resolve(focusActive: true, meeting: meeting, musicPlaying: true, visible: all, indicators: every) == .meeting(meeting))
        #expect(CollapsedLive.resolve(focusActive: true, meeting: nil, musicPlaying: true, visible: all, indicators: every) == .focus)
        #expect(CollapsedLive.resolve(focusActive: false, meeting: nil, musicPlaying: true, visible: all, indicators: every) == .music)
        #expect(CollapsedLive.resolve(focusActive: false, meeting: nil, musicPlaying: false, visible: all, indicators: every) == .none)
    }

    @Test func hiddenModulesAndIndicatorsAreSkipped() {
        let noCalendar = all.subtracting([.calendar])
        #expect(CollapsedLive.resolve(focusActive: true, meeting: meeting, musicPlaying: true, visible: noCalendar, indicators: every) == .focus)
        #expect(CollapsedLive.resolve(focusActive: true, meeting: meeting, musicPlaying: true, visible: all, indicators: [.music]) == .music)
        #expect(CollapsedLive.resolve(focusActive: true, meeting: meeting, musicPlaying: true, visible: all, indicators: []) == .none)
    }

    @Test func clickOpensTheModuleOfWhatIsShown() {
        #expect(CollapsedLive.focus.tab == .focus)
        #expect(CollapsedLive.meeting(meeting).tab == .calendar)
        #expect(CollapsedLive.music.tab == .music)
        #expect(CollapsedLive.none.tab == nil)
    }
}

@MainActor
struct ModuleSettingsTests {
    @Test func defaultsFollowTheDesign() {
        let modules = ModuleSettings(defaults: freshDefaults())
        #expect(modules.visible == [.calendar, .clipboard, .notes, .focus, .music, .shelf])
        #expect(modules.defaultTab == nil)
        #expect(modules.indicators == Set(CollapsedIndicator.allCases))
    }

    @Test func hideReorderAndPersist() {
        let defaults = freshDefaults()
        let modules = ModuleSettings(defaults: defaults)
        modules.setVisible(.clipboard, false)
        modules.move(.shelf, by: -1)
        modules.setDefault(.notes)
        modules.setIndicator(.music, false)

        let again = ModuleSettings(defaults: defaults)
        #expect(again.visible == [.calendar, .notes, .focus, .shelf, .music])
        #expect(again.defaultTab == .notes)
        #expect(again.indicators == [.focus, .meeting])
    }

    @Test func theLastModuleCantBeHidden() {
        let modules = ModuleSettings(defaults: freshDefaults())
        for tab in IslandTab.allCases { modules.setVisible(tab, false) }
        #expect(modules.visible.count == 1)
    }

    @Test func hidingTheDefaultFallsBackToLastUsed() {
        let modules = ModuleSettings(defaults: freshDefaults())
        modules.setDefault(.focus)
        modules.setVisible(.focus, false)
        #expect(modules.defaultTab == nil)
    }

    @Test func unknownOrMissingSavedModulesAreTolerated() {
        let defaults = freshDefaults()
        defaults.set(["shelf", "nonsense", "music"], forKey: ModuleKeys.order) // e.g. written by an older version
        let modules = ModuleSettings(defaults: defaults)
        #expect(modules.order == [.shelf, .music, .calendar, .clipboard, .notes, .focus])
    }
}

@MainActor
struct ModuleIntegrationTests {
    private func island(_ defaults: UserDefaults = freshDefaults()) -> (IslandModel, FocusModule, ModuleSettings) {
        let modules = ModuleSettings(defaults: defaults)
        let focus = FocusModule(defaults: defaults, notifier: SilentNotifier())
        return (IslandModel(focus: focus, modules: modules), focus, modules)
    }

    @Test func disablingAModuleRemovesItWithoutAffectingOthers() {
        let (model, focus, modules) = island()
        model.tab = .focus
        focus.begin()
        model.notes.currentText = "kept"
        modules.setVisible(.focus, false)
        #expect(!focus.isActive) // the session ended with its module
        #expect(model.tab != .focus)
        #expect(model.notes.currentText == "kept")
        #expect(model.collapsedLive == .none)
    }

    @Test func clickingTheCollapsedIslandOpensTheLiveModule() {
        let (model, focus, modules) = island()
        modules.setDefault(.notes)
        model.tap()
        #expect(model.tab == .notes)
        model.dismiss()
        focus.begin()
        model.tap()
        #expect(model.tab == .focus)
    }

    @Test func liveStatesNeverSwitchAnOpenModule() {
        let (model, focus, _) = island()
        model.tab = .notes
        model.tap()
        #expect(model.tab == .notes)
        focus.begin() // something live starts while the user is in Notes
        #expect(model.tab == .notes)
        #expect(model.state == .pinned)
    }

    @Test func controlTabCyclesThroughVisibleModules() {
        let (model, _, modules) = island()
        modules.setVisible(.clipboard, false)
        model.tab = .calendar
        model.selectAdjacentTab(1)
        #expect(model.tab == .notes) // the hidden Clipboard is skipped
        model.tab = .calendar
        model.selectAdjacentTab(-1)
        #expect(model.tab == .shelf) // wraps around
    }

    @Test func aHiddenShelfTakesNoDrops() {
        let (model, _, modules) = island()
        modules.setVisible(.shelf, false)
        model.dragEntered(valid: true)
        #expect(!model.dropIsValid)
    }

    @Test func collapsedWidthFollowsWhatIsShown() {
        let (model, focus, modules) = island()
        #expect(model.liveCollapsedWidth == nil)
        focus.begin()
        #expect(model.liveCollapsedWidth == IslandGeometry.focusWidth)
        modules.setIndicator(.focus, false)
        #expect(model.liveCollapsedWidth == nil)
    }
}

private struct SilentNotifier: FocusNotifier {
    func authorize() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func schedule(at date: Date, minutes: Int) async {}
    func cancel() async {}
}
