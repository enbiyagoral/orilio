import Foundation
import Testing
@testable import OrilioPrototype

@MainActor
private func fresh() -> UserDefaults { UserDefaults(suiteName: "orilio.onboarding.\(UUID().uuidString)")! }

@MainActor
struct OnboardingTests {
    private func island(_ defaults: UserDefaults) -> IslandModel {
        IslandModel(modules: ModuleSettings(defaults: defaults),
                    mirror: CameraMirrorModel(defaults: defaults, observeSystem: false))
    }

    @Test func firstLaunchShowsItSecondDoesntReplayResets() {
        let defaults = fresh()
        #expect(OnboardingModel.shouldShow(defaults))
        let model = island(defaults)
        model.startOnboarding(defaults: defaults, loginStatus: .off)
        #expect(model.onboarding != nil && model.state == .pinned)
        // The test geometry has no notch: the 760 × 480 panel floats 6 pt below the menu bar band.
        #expect(model.onboardingFloats)
        #expect(model.customPanel(for: .pinned) == CGSize(width: 760, height: 480 + model.geometry.topInset + 6))
        while model.onboarding.map({ !$0.next() }) ?? false {} // Get started, Continue, Continue, Done
        model.finishOnboarding()
        #expect(!OnboardingModel.shouldShow(defaults)) // the second launch skips it
        #expect(model.state == .collapsed)
        #expect(model.showsLivesHereHint)
        OnboardingModel.reset(defaults)
        #expect(OnboardingModel.shouldShow(defaults))
    }

    @Test func choicesMapToModuleVisibility() {
        let defaults = fresh()
        let modules = ModuleSettings(defaults: defaults)
        let flow = OnboardingModel(modules: modules, defaults: defaults, loginStatus: .off)
        #expect(flow.chosen == OnboardingModel.defaultModules) // a new user: the design's defaults
        flow.toggle(.clipboard)
        flow.toggle(.shelf)
        flow.finish()
        #expect(modules.visibleSet == [.calendar, .music, .focus, .notes, .clipboard])
        #expect(!modules.isVisible(.mirror))
    }

    @Test func escFinishesWithTheCurrentChoices() {
        let defaults = fresh()
        let model = island(defaults)
        model.startOnboarding(defaults: defaults, loginStatus: .off)
        _ = model.onboarding?.next()
        model.onboarding?.toggle(.mirror)
        model.dismiss() // Esc and the close button go through here
        #expect(model.onboarding == nil)
        #expect(model.modules.isVisible(.mirror))
        #expect(!OnboardingModel.shouldShow(defaults))
    }

    @Test func noPermissionIsAskedFor() {
        let defaults = fresh()
        let model = island(defaults)
        model.startOnboarding(defaults: defaults, loginStatus: .off)
        model.onboarding?.toggle(.clipboard)
        model.onboarding?.toggle(.mirror)
        model.finishOnboarding()
        // Choosing modules only sets visibility: nothing was turned on or asked for.
        #expect(model.calendar.status == .off)
        #expect(model.clipboard.status == .off)
        #expect(model.mirror.state == .off)
    }

    @Test func oneModuleAlwaysStaysAndExistingChoicesAreKept() {
        let defaults = fresh()
        let modules = ModuleSettings(defaults: defaults)
        modules.setVisible(.clipboard, false) // someone who set things up before
        let flow = OnboardingModel(modules: modules, defaults: defaults, loginStatus: .off)
        #expect(flow.chosen == modules.visibleSet)
        for tab in IslandTab.allCases { flow.toggle(tab) }
        #expect(!flow.chosen.isEmpty)
    }

    @Test func loginUsesTheRealService() {
        let defaults = fresh()
        var asked: [Bool] = []
        let flow = OnboardingModel(modules: ModuleSettings(defaults: defaults), defaults: defaults, loginStatus: .off,
                                   loginItem: { asked.append($0); return $0 ? .enabled : .off })
        flow.setLogin(true)
        #expect(asked == [true])
        #expect(flow.login == .enabled)
    }
}
