// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

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

    @Test func generalAndShortcutsRoundTrip() throws {
        let defaults = freshDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.value.openOnHover = false
        store.value.haptics = false
        store.value.hoverDelay = 240
        store.value.shortcuts[ShortcutAction.openClipboard.rawValue] = .controlOption(9, "V") // still ⌃⌥V
        store.value.shortcuts[ShortcutAction.openMirror.rawValue] = HotKeyCombo.none
        let again = PreferencesStore(defaults: defaults).value
        #expect(again == store.value)
        #expect(again.shortcut(.openMirror).isNone)
        #expect(again.shortcut(.toggleFocus) == ShortcutAction.toggleFocus.defaultCombo)
        #expect(again.shortcut(.toggleIsland).keycaps == ["⌃", "⌥", "Space"])
    }

    @Test func exportThenImportGivesTheSameSettings() throws {
        var p = Preferences()
        p.theme = .neon
        p.sounds = false
        p.shortcuts[ShortcutAction.newNote.rawValue] = HotKeyCombo(keyCode: 45, modifiers: 256 | 2048, key: "N") // ⌘⌥N
        #expect(try Preferences.imported(from: p.exported()) == p)
    }

    @Test func importRejectsWhatIsNotOrilioSettings() {
        for text in ["not json", "[1, 2]", #"{"theme": "neon"}"#, #"{"version": "1", "theme": "neon"}"#, #"{"version": 1, "name": "x"}"#] {
            #expect(throws: Preferences.ImportError.self) { try Preferences.imported(from: Data(text.utf8)) }
        }
        #expect(throws: Preferences.ImportError.self) { try Preferences.imported(from: Data(#"{"version": 9, "theme": "neon"}"#.utf8)) }
    }

    @Test func importKeepsDefaultsForBadValues() throws {
        let p = try Preferences.imported(from: Data(#"{"version": 1, "hoverDelay": 9000, "accent": "plaid", "shortcuts": {"launchRockets": {"keyCode": 1, "modifiers": 4096, "key": "S"}}}"#.utf8))
        #expect(p.hoverDelay == 500) // clamped to the slider
        #expect(p.accent == .mint)
        #expect(p.shortcuts.isEmpty) // unknown actions are dropped
    }

    @Test func openOnHoverCarriesOverFromItsOldKey() {
        let defaults = freshDefaults()
        PreferencesStore(defaults: defaults).value.theme = .calm
        defaults.set(false, forKey: SettingsKeys.openOnHover)
        #expect(!Preferences.load(defaults).openOnHover)
        #expect(defaults.object(forKey: SettingsKeys.openOnHover) == nil)
        #expect(!Preferences.load(defaults).openOnHover) // saved, not just read once
    }

    @Test func theOldModuleKeysSurviveTheHoverCarryOver() {
        let defaults = freshDefaults()
        defaults.set(["music", "calendar"], forKey: "modules.order")
        defaults.set(false, forKey: SettingsKeys.openOnHover) // both old forms at once, no stored value yet
        _ = Preferences.load(defaults)
        let again = Preferences.load(defaults) // now from the saved value
        #expect(Array(again.moduleOrder.prefix(2)) == ["music", "calendar"])
        #expect(!again.openOnHover)
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
