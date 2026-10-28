// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation
import SwiftUI

/// The user's customization, stored as one versioned value (`preferences.v1`). Every field decodes
/// on its own with a default, so a value written by an older or newer Orilio still loads.
struct Preferences: Codable, Equatable {
    static let key = "preferences.v1"

    enum OpenWith: String, Codable, CaseIterable, Identifiable {
        case live, last, first
        var id: Self { self }
        var title: String {
            switch self {
            case .live: "Live activity"
            case .last: "Last used"
            case .first: "First in list"
            }
        }
    }

    enum PanelSize: String, Codable, CaseIterable, Identifiable {
        case compact, standard, large
        var id: Self { self }
        var title: String { rawValue.capitalized }
        /// The open panel's width; its content height scales with it.
        var width: CGFloat {
            switch self {
            case .compact: 560
            case .standard: 700
            case .large: 820
            }
        }
    }

    enum ThemeStyle: String, Codable, CaseIterable, Identifiable {
        case calm, neon, adaptive
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var detail: String {
            switch self {
            case .calm: "White accents, artwork tint only"
            case .neon: "Accent glows everywhere"
            case .adaptive: "Calm at rest, neon when live"
            }
        }
    }

    enum Accent: String, Codable, CaseIterable, Identifiable {
        case mint, cyan, magenta, volt, orange
        var id: Self { self }
        var title: String {
            switch self {
            case .mint: "Cyber Mint"
            case .cyan: "Electric Cyan"
            case .magenta: "Hot Magenta"
            case .volt: "Volt"
            case .orange: "Neon Orange"
            }
        }
        var color: Color {
            switch self {
            case .mint: Color(red: 0.169, green: 1, blue: 0.722)    // #2BFFB8
            case .cyan: Color(red: 0, green: 0.898, blue: 1)        // #00E5FF
            case .magenta: Color(red: 1, green: 0.169, blue: 0.839) // #FF2BD6
            case .volt: Color(red: 0.831, green: 1, blue: 0.227)    // #D4FF3A
            case .orange: Color(red: 1, green: 0.478, blue: 0.102)  // #FF7A1A
            }
        }
    }

    enum Motion: String, Codable, CaseIterable, Identifiable {
        case spring, subtle, off
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    var version = 1
    var moduleOrder: [String] = IslandTab.allCases.map(\.key)
    var hiddenModules: [String] = []
    var openWith = OpenWith.live
    var hiddenIndicators: [String] = []
    var panelSize = PanelSize.standard
    var theme = ThemeStyle.adaptive
    var accent = Accent.mint
    var motion = Motion.spring
    var followReduceMotion = true
    /// Camera Mirror is the one module that starts hidden; this turns it on.
    var mirrorEnabled = false
    // Settings › General
    var openOnHover = true
    var haptics = true
    var sounds = true
    /// Milliseconds the pointer rests on the notch before the island peeks (0–500).
    var hoverDelay = 90
    /// Settings › Shortcuts, by `ShortcutAction` raw value; a missing one keeps its default.
    var shortcuts: [String: HotKeyCombo] = [:]

    init() {}

    func shortcut(_ action: ShortcutAction) -> HotKeyCombo { shortcuts[action.rawValue] ?? action.defaultCombo }
    var shortcutMap: [ShortcutAction: HotKeyCombo] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, shortcut($0)) })
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        version = value(.version, d.version)
        moduleOrder = value(.moduleOrder, d.moduleOrder)
        hiddenModules = value(.hiddenModules, d.hiddenModules)
        openWith = value(.openWith, d.openWith)
        hiddenIndicators = value(.hiddenIndicators, d.hiddenIndicators)
        panelSize = value(.panelSize, d.panelSize)
        theme = value(.theme, d.theme)
        accent = value(.accent, d.accent)
        motion = value(.motion, d.motion)
        followReduceMotion = value(.followReduceMotion, d.followReduceMotion)
        mirrorEnabled = value(.mirrorEnabled, d.mirrorEnabled)
        openOnHover = value(.openOnHover, d.openOnHover)
        haptics = value(.haptics, d.haptics)
        sounds = value(.sounds, d.sounds)
        hoverDelay = min(500, max(0, value(.hoverDelay, d.hoverDelay)))
        shortcuts = value(.shortcuts, d.shortcuts).filter { ShortcutAction(rawValue: $0.key) != nil }
    }

    enum ImportError: LocalizedError {
        case notSettings, newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .notSettings: "This file doesn't contain Orilio settings."
            case .newerVersion(let v): "These settings come from a newer Orilio (format \(v)). Update Orilio to import them."
            }
        }
    }

    /// Settings › General › Export settings…: the stored value, readable.
    func exported() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Import settings…: only a JSON object carrying Orilio's format version is accepted; each field
    /// then decodes on its own, so a bad value keeps its default instead of failing the file.
    static func imported(from data: Data) throws -> Preferences {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version >= 1,
              object.keys.contains(where: { CodingKeys(stringValue: $0) != nil && $0 != "version" }) else { throw ImportError.notSettings }
        guard version <= Preferences().version else { throw ImportError.newerVersion(version) }
        return try JSONDecoder().decode(Preferences.self, from: data)
    }

    /// The stored value; on first run after M3.5, the module keys it replaces are carried over.
    static func load(_ defaults: UserDefaults) -> Preferences {
        if let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Preferences.self, from: data) {
            return stored.carryingOver(defaults)
        }
        var migrated = Preferences().carryingOver(defaults)
        if let order = defaults.stringArray(forKey: "modules.order") { migrated.moduleOrder = order }
        if let hidden = defaults.stringArray(forKey: "modules.hidden") { migrated.hiddenModules = hidden }
        if let indicators = defaults.stringArray(forKey: "modules.hiddenIndicators") { migrated.hiddenIndicators = indicators }
        // "Open to <module>" (M3.5) has no exact match; a fixed module is closest to "First in list".
        if defaults.string(forKey: "modules.default") != nil { migrated.openWith = .first }
        return migrated
    }

    /// "Open on hover" was its own key before M5.3.
    private func carryingOver(_ defaults: UserDefaults) -> Preferences {
        var p = self
        if let hover = defaults.object(forKey: SettingsKeys.openOnHover) as? Bool {
            p.openOnHover = hover
            defaults.removeObject(forKey: SettingsKeys.openOnHover)
            p.save(to: defaults)
        }
        return p
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// The live preferences: every change applies at once and is saved.
@MainActor @Observable
final class PreferencesStore {
    var value: Preferences {
        didSet { if value != oldValue { value.save(to: defaults) } }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = Preferences.load(defaults)
    }

    /// The app's store; views read the theme through it (see `Theme.current`).
    static var shared = PreferencesStore()
}
