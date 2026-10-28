// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Carbon.HIToolbox
import Testing
@testable import OrilioPrototype

struct ShortcutsTests {
    private var defaults: [ShortcutAction: HotKeyCombo] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultCombo) })
    }

    @Test func defaultsAreAllControlOptionAndDistinct() {
        let plan = HotKeyPlan.resolve(defaults, hidden: [])
        #expect(plan.register.count == 6 && plan.conflicts.isEmpty)
        #expect(ShortcutAction.openClipboard.defaultCombo.keycaps == ["⌃", "⌥", "V"])
    }

    @Test func aDuplicateGoesToTheFirstAndTheOtherIsAConflict() {
        var combos = defaults
        combos[.openMirror] = combos[.openClipboard]
        let plan = HotKeyPlan.resolve(combos, hidden: [])
        #expect(plan.conflicts == [.openMirror])
        #expect(plan.register.map(\.0).contains(.openClipboard))
        #expect(!plan.register.map(\.0).contains(.openMirror))
    }

    @Test func clearedAndHiddenRegisterNothingAndConflictWithNothing() {
        var combos = defaults
        combos[.newNote] = HotKeyCombo.none
        combos[.joinMeeting] = combos[.openMirror] // the mirror is hidden, so this is no conflict
        let plan = HotKeyPlan.resolve(combos, hidden: [.mirror])
        #expect(plan.conflicts.isEmpty)
        #expect(Set(plan.register.map(\.0)) == [.toggleIsland, .openClipboard, .toggleFocus, .joinMeeting])
    }

    @Test func sameKeysWithDifferentModifiersDontConflict() {
        var combos = defaults
        combos[.openMirror] = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")
        #expect(HotKeyPlan.resolve(combos, hidden: []).conflicts.isEmpty)
        #expect(combos[.openMirror]!.keycaps == ["⇧", "⌘", "V"])
    }
}
