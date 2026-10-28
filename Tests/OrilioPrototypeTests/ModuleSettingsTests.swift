import Foundation
import Testing
@testable import OrilioPrototype

@MainActor
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "orilio.modules.\(UUID().uuidString)")! }

private let meeting = CalendarEvent(id: "m", eventIdentifier: nil, title: "Design review", start: .now, end: .now.addingTimeInterval(1_800),
                                    isAllDay: false, calendarID: "work", calendarTitle: "Work", sourceTitle: "Google",
                                    color: .fallback, attendeeNames: [], meeting: nil)

@MainActor
struct ModuleSettingsTests {
    @Test func defaultsFollowTheDesign() {
        let modules = ModuleSettings(defaults: freshDefaults())
        #expect(modules.visible == [.calendar, .focus, .music, .clipboard, .notes, .shelf]) // the M4 Settings order; Camera Mirror starts off
        #expect(modules.openWith == .live)
        #expect(modules.indicators == Set(CollapsedIndicator.allCases))
    }

    @Test func hideReorderAndPersist() {
        let defaults = freshDefaults()
        let modules = ModuleSettings(defaults: defaults)
        modules.setVisible(.clipboard, false)
        modules.move(.shelf, by: -1)
        modules.setOpenWith(.first)
        modules.setIndicator(.music, false)

        let again = ModuleSettings(defaults: defaults)
        #expect(again.visible == [.calendar, .focus, .music, .shelf, .notes])
        #expect(again.openWith == .first)
        #expect(again.indicators == [.focus, .meeting])
    }

    @Test func theLastModuleCantBeHidden() {
        let modules = ModuleSettings(defaults: freshDefaults())
        for tab in IslandTab.allCases { modules.setVisible(tab, false) }
        #expect(modules.visible.count == 1)
    }

    @Test func dragReorderChangesTheTabOrder() {
        let modules = ModuleSettings(defaults: freshDefaults())
        modules.move(from: [5], to: 0) // Shelf to the front
        #expect(modules.visible.first == .shelf)
        modules.move(.shelf, by: 1)
        #expect(modules.visible.prefix(2) == [.calendar, .shelf])
    }

    @Test func unknownOrMissingSavedModulesAreTolerated() {
        let defaults = freshDefaults()
        defaults.set(["shelf", "nonsense", "music"], forKey: "modules.order") // written by M3.5, migrated
        let modules = ModuleSettings(defaults: defaults)
        #expect(modules.order == [.shelf, .music, .calendar, .focus, .clipboard, .notes, .mirror])
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
        #expect(model.earLayout.isIdle)
    }

    @Test func whenTheIslandOpensShow() {
        let (model, focus, modules) = island()
        model.tab = .notes
        model.tap() // live, nothing live: stays on the last module
        #expect(model.tab == .notes)
        model.dismiss()
        focus.begin()
        model.tap() // live: the focus session
        #expect(model.tab == .focus)
        model.dismiss()
        modules.setOpenWith(.last)
        model.tab = .notes
        model.tap()
        #expect(model.tab == .notes)
        model.dismiss()
        modules.setOpenWith(.first)
        model.tap()
        #expect(model.tab == modules.visible[0])
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
        model.tab = .music
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
        #expect(model.liveCollapsedWidth != nil)
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
