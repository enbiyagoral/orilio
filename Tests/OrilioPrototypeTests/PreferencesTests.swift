import Foundation
import SwiftUI
import Testing
@testable import OrilioPrototype

@MainActor
private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "orilio.prefs.\(UUID().uuidString)")! }

@MainActor
struct PreferencesTests {
    @Test func defaults() {
        let p = Preferences.load(freshDefaults())
        #expect(p.version == 1)
        #expect(p.openWith == .live && p.panelSize == .standard && p.theme == .adaptive && p.accent == .mint)
        #expect(p.motion == .spring && p.followReduceMotion)
        #expect(p.moduleOrder == IslandTab.allCases.map(\.key))
    }

    @Test func roundTripsThroughOneStoredValue() {
        let defaults = freshDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.value.panelSize = .large
        store.value.theme = .neon
        store.value.accent = .magenta
        store.value.motion = .off
        store.value.followReduceMotion = false
        #expect(defaults.data(forKey: Preferences.key) != nil)
        let again = PreferencesStore(defaults: defaults).value
        #expect(again == store.value)
    }

    @Test func migratesTheM35ModuleKeys() {
        let defaults = freshDefaults()
        defaults.set(["music", "calendar"], forKey: "modules.order")
        defaults.set(["clipboard"], forKey: "modules.hidden")
        defaults.set(["music"], forKey: "modules.hiddenIndicators")
        defaults.set("notes", forKey: "modules.default")
        let p = Preferences.load(defaults)
        #expect(p.moduleOrder == ["music", "calendar"])
        #expect(p.hiddenModules == ["clipboard"])
        #expect(p.hiddenIndicators == ["music"])
        #expect(p.openWith == .first)
        #expect(p.panelSize == .standard) // new fields start at their defaults
    }

    @Test func unknownOrMissingFieldsFallBackOneByOne() throws {
        let defaults = freshDefaults()
        let partial = #"{"version": 1, "theme": "calm", "panelSize": "gigantic", "futureField": 3}"#
        defaults.set(Data(partial.utf8), forKey: Preferences.key)
        let p = Preferences.load(defaults)
        #expect(p.theme == .calm)
        #expect(p.panelSize == .standard) // an unknown size keeps the default
        #expect(p.accent == .mint)
    }

    @Test func panelSizeSetsTheOpenWidthAndScalesTheHeight() {
        var g = IslandGeometry(topInset: 32, notchWidth: 179, centerX: 0, screenTop: 0)
        g.panelWidth = Preferences.PanelSize.compact.width
        #expect(g.full == CGSize(width: 560, height: 38 + 213))
        g.panelWidth = Preferences.PanelSize.large.width
        #expect(g.full == CGSize(width: 820, height: 38 + 312))
        #expect(g.collapsed == CGSize(width: 179, height: 32)) // collapsed is unchanged
    }
}

struct ThemeTests {
    private func theme(_ style: Preferences.ThemeStyle, motion: Preferences.Motion = .spring,
                       follow: Bool = true, systemReduceMotion: Bool = false) -> Theme {
        var p = Preferences()
        p.theme = style
        p.accent = .cyan
        p.motion = motion
        p.followReduceMotion = follow
        return Theme.resolve(p, systemReduceMotion: systemReduceMotion)
    }

    @Test func calmIsWhiteWithoutGlow() {
        let calm = theme(.calm)
        for role in [Theme.Role.rest, .action, .live] {
            #expect(calm.color(role) == .white)
            #expect(calm.glow(role) == 0)
        }
    }

    @Test func neonGlowsEverywhere() {
        let neon = theme(.neon)
        for role in [Theme.Role.rest, .action, .live] {
            #expect(neon.color(role) == Preferences.Accent.cyan.color)
            #expect(neon.glow(role) == 1)
        }
    }

    @Test func adaptiveIsCalmAtRestAndNeonWhenLiveOrActionable() {
        let adaptive = theme(.adaptive)
        #expect(adaptive.color(.rest) == .white && adaptive.glow(.rest) == 0)
        #expect(adaptive.color(.live) == Preferences.Accent.cyan.color && adaptive.glow(.live) == 1)
        #expect(adaptive.color(.action) == Preferences.Accent.cyan.color && adaptive.glow(.action) == 1)
    }

    @Test func reduceMotionOverridesTheChoiceWhenFollowed() {
        #expect(theme(.adaptive, motion: .spring, systemReduceMotion: true).motion == .off)
        #expect(theme(.adaptive, motion: .spring, systemReduceMotion: true).spring(duration: 0.3) == nil)
        #expect(theme(.adaptive, motion: .spring, follow: false, systemReduceMotion: true).motion == .spring)
        #expect(theme(.adaptive, motion: .subtle).spring(duration: 0.4, bounce: 0.2) == .spring(duration: 0.34, bounce: 0))
        #expect(theme(.adaptive, motion: .off).reducesMotion)
    }
}
