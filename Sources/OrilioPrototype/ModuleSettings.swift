// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Observation

/// What the collapsed island may show besides the notch itself.
enum CollapsedIndicator: String, CaseIterable, Identifiable {
    case focus, meeting, music
    var id: Self { self }

    var title: String {
        switch self {
        case .focus: "Focus timer"
        case .meeting: "Meeting about to start"
        case .music: "Music playing"
        }
    }
}

extension IslandTab {
    /// Stable identifier for preferences (the raw value is the display name).
    var key: String { String(describing: self) }
    init?(key: String) {
        guard let tab = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = tab
    }
}

/// The module registry: which modules the island shows, in which order (= tab order), what it opens
/// to, and which live states the collapsed island may show. The tab bar and the live-activity
/// resolver both read it. Stored in `Preferences`.
@MainActor @Observable
final class ModuleSettings {
    @ObservationIgnored let store: PreferencesStore
    /// Called when a module is hidden, so it can stop its work (and give up what it reads).
    /// Every display's island registers (each moves off the hidden tab).
    @ObservationIgnored private var hideHandlers: [(IslandTab) -> Void] = []

    func whenHidden(_ handler: @escaping (IslandTab) -> Void) { hideHandlers.append(handler) }

    init(store: PreferencesStore) {
        self.store = store
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(store: PreferencesStore(defaults: defaults))
    }

    private var preferences: Preferences {
        get { store.value }
        set { store.value = newValue }
    }

    /// Saved order first; modules added in a later version go at the end. Unknown keys are dropped.
    var order: [IslandTab] {
        let saved = preferences.moduleOrder.compactMap(IslandTab.init(key:))
        return saved + IslandTab.allCases.filter { !saved.contains($0) }
    }

    var hidden: Set<IslandTab> {
        var hidden = Set(preferences.hiddenModules.compactMap(IslandTab.init(key:)))
        if !preferences.mirrorEnabled { hidden.insert(.mirror) } // off by default
        // Never all of them. Extensions don't count: they're only shown while an extension has
        // something for the island, which isn't the case at launch.
        let always = IslandTab.allCases.filter { $0 != .extensions }
        return always.allSatisfy(hidden.contains) ? [.mirror] : hidden
    }

    var openWith: Preferences.OpenWith { preferences.openWith }

    var indicators: Set<CollapsedIndicator> {
        Set(CollapsedIndicator.allCases).subtracting(preferences.hiddenIndicators.compactMap(CollapsedIndicator.init(rawValue:)))
    }

    /// The Extensions tab shows only while an enabled extension has something for the island
    /// (set by the app; nothing in tests).
    @ObservationIgnored var extensionsAvailable: () -> Bool = { false }

    var visible: [IslandTab] { order.filter { !hidden.contains($0) && ($0 != .extensions || extensionsAvailable()) } }
    var visibleSet: Set<IslandTab> { Set(visible) }

    func isVisible(_ tab: IslandTab) -> Bool { !hidden.contains(tab) }

    /// At least one module always stays.
    func setVisible(_ tab: IslandTab, _ on: Bool) {
        if on {
            if tab == .mirror { preferences.mirrorEnabled = true }
            preferences.hiddenModules.removeAll { $0 == tab.key }
        } else {
            // A module other than Extensions has to stay (see `hidden`).
            guard visible.contains(where: { $0 != tab && $0 != .extensions }), !hidden.contains(tab) else { return }
            if tab == .mirror { preferences.mirrorEnabled = false } else { preferences.hiddenModules.append(tab.key) }
            hideHandlers.forEach { $0(tab) }
        }
    }

    func move(_ tab: IslandTab, by offset: Int) {
        var order = order
        guard let index = order.firstIndex(of: tab), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        preferences.moduleOrder = order.map(\.key)
    }

    /// Drag to reorder (positions in `order`).
    func move(from source: IndexSet, to destination: Int) {
        var order = order
        order.move(fromOffsets: source, toOffset: destination)
        preferences.moduleOrder = order.map(\.key)
    }

    func setOpenWith(_ mode: Preferences.OpenWith) { preferences.openWith = mode }

    func setIndicator(_ indicator: CollapsedIndicator, _ on: Bool) {
        var off = Set(preferences.hiddenIndicators)
        if on { off.remove(indicator.rawValue) } else { off.insert(indicator.rawValue) }
        preferences.hiddenIndicators = off.sorted()
    }
}
