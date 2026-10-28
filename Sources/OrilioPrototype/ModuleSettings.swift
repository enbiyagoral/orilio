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

enum ModuleKeys {
    static let order = "modules.order"
    static let hidden = "modules.hidden"
    static let defaultTab = "modules.default" // a tab's key, or absent for "last used"
    static let hiddenIndicators = "modules.hiddenIndicators"
}

extension IslandTab {
    /// Stable identifier for preferences (the raw value is the display name).
    var key: String { String(describing: self) }
    init?(key: String) {
        guard let tab = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = tab
    }
}

/// Which modules the island shows, in which order, which one it opens to, and which live states
/// the collapsed island may show. Stored in `UserDefaults` (`modules.*`).
@MainActor @Observable
final class ModuleSettings {
    private(set) var order: [IslandTab]
    private(set) var hidden: Set<IslandTab>
    /// nil: open to the module used last.
    private(set) var defaultTab: IslandTab?
    private(set) var indicators: Set<CollapsedIndicator>

    @ObservationIgnored private let defaults: UserDefaults
    /// Called when a module is hidden, so it can stop its work (and give up what it reads).
    /// Every display's island registers (each moves off the hidden tab).
    @ObservationIgnored private var hideHandlers: [(IslandTab) -> Void] = []

    func whenHidden(_ handler: @escaping (IslandTab) -> Void) { hideHandlers.append(handler) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.stringArray(forKey: ModuleKeys.order) ?? []).compactMap(IslandTab.init(key:))
        // Saved order first; modules added in a later version go at their design position's end.
        order = saved + IslandTab.allCases.filter { !saved.contains($0) }
        let hidden = Set((defaults.stringArray(forKey: ModuleKeys.hidden) ?? []).compactMap(IslandTab.init(key:)))
        self.hidden = hidden.count == IslandTab.allCases.count ? [] : hidden
        defaultTab = defaults.string(forKey: ModuleKeys.defaultTab).flatMap(IslandTab.init(key:))
        let off = Set((defaults.stringArray(forKey: ModuleKeys.hiddenIndicators) ?? []).compactMap(CollapsedIndicator.init(rawValue:)))
        indicators = Set(CollapsedIndicator.allCases).subtracting(off)
    }

    var visible: [IslandTab] { order.filter { !hidden.contains($0) } }
    var visibleSet: Set<IslandTab> { Set(visible) }

    func isVisible(_ tab: IslandTab) -> Bool { !hidden.contains(tab) }

    /// At least one module always stays.
    func setVisible(_ tab: IslandTab, _ on: Bool) {
        if on {
            hidden.remove(tab)
        } else {
            guard visible.count > 1, !hidden.contains(tab) else { return }
            hidden.insert(tab)
            if defaultTab == tab { setDefault(nil) }
            hideHandlers.forEach { $0(tab) }
        }
        defaults.set(hidden.map(\.key).sorted(), forKey: ModuleKeys.hidden)
    }

    func move(_ tab: IslandTab, by offset: Int) {
        guard let index = order.firstIndex(of: tab), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        defaults.set(order.map(\.key), forKey: ModuleKeys.order)
    }

    func setDefault(_ tab: IslandTab?) {
        defaultTab = tab
        if let tab { defaults.set(tab.key, forKey: ModuleKeys.defaultTab) } else { defaults.removeObject(forKey: ModuleKeys.defaultTab) }
    }

    func setIndicator(_ indicator: CollapsedIndicator, _ on: Bool) {
        if on { indicators.insert(indicator) } else { indicators.remove(indicator) }
        let off = CollapsedIndicator.allCases.filter { !indicators.contains($0) }
        defaults.set(off.map(\.rawValue), forKey: ModuleKeys.hiddenIndicators)
    }

    func resetOrder() {
        order = IslandTab.allCases
        defaults.removeObject(forKey: ModuleKeys.order)
    }
}
