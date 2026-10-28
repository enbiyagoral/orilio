import AppKit

/// Where the island appears: which displays, in fullscreen apps, on Spaces. `UserDefaults`, `displays.*`.
struct DisplaySettings: Equatable {
    enum Placement: String, CaseIterable, Identifiable {
        case builtIn, all, pointer
        var id: Self { self }
        var title: String {
            switch self {
            case .builtIn: "Built-in display only"
            case .all: "All displays"
            case .pointer: "Display with the pointer"
            }
        }
    }

    enum Fullscreen: String, CaseIterable, Identifiable {
        case hide, reveal, show
        var id: Self { self }
        var title: String {
            switch self {
            case .hide: "Hide"
            case .reveal: "Reveal from the top edge"
            case .show: "Always show"
            }
        }
    }

    var placement = Placement.pointer
    var fullscreen = Fullscreen.reveal
    var allSpaces = true
    var externalWhenLidClosed = true

    enum Keys {
        static let placement = "displays.placement"
        static let fullscreen = "displays.fullscreen"
        static let allSpaces = "displays.allSpaces"
        static let externalWhenLidClosed = "displays.externalWhenLidClosed"
    }

    init() {}

    init(_ defaults: UserDefaults) {
        if let raw = defaults.string(forKey: Keys.placement), let placement = Placement(rawValue: raw) {
            self.placement = placement
        } else if defaults.bool(forKey: SettingsKeys.preferNotchedDisplay) {
            placement = .builtIn // the M1 "show on the built-in notched display" switch
        }
        fullscreen = defaults.string(forKey: Keys.fullscreen).flatMap(Fullscreen.init(rawValue:)) ?? .reveal
        allSpaces = defaults.object(forKey: Keys.allSpaces) as? Bool ?? true
        externalWhenLidClosed = defaults.object(forKey: Keys.externalWhenLidClosed) as? Bool ?? true
    }
}

/// What the resolver needs to know about one display. Built from `NSScreen` in the app, by hand in tests.
struct ScreenInfo: Equatable {
    let id: CGDirectDisplayID
    /// AppKit coordinates (origin at the bottom left of the primary display).
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxLeftWidth: CGFloat?
    let auxRightWidth: CGFloat?
    let isBuiltIn: Bool
    let scale: CGFloat

    var geometry: IslandGeometry {
        let band = frame.maxY - visibleFrame.maxY
        var geometry = IslandGeometry.make(screenFrame: frame, safeAreaTop: safeAreaTop,
                                           auxLeftWidth: auxLeftWidth, auxRightWidth: auxRightWidth,
                                           // band is 0 when the menu bar auto-hides
                                           menuBarHeight: band > 0 ? band : 24, scale: scale)
        geometry.usableHeight = visibleFrame.height
        return geometry
    }
}

extension ScreenInfo {
    @MainActor init?(_ screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        self.init(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                  auxLeftWidth: screen.auxiliaryTopLeftArea?.width, auxRightWidth: screen.auxiliaryTopRightArea?.width,
                  isBuiltIn: CGDisplayIsBuiltin(id) != 0, scale: screen.backingScaleFactor)
    }
}

/// Which displays get an island. Pure.
enum ScreenResolver {
    /// - Parameters:
    ///   - screens: in `NSScreen.screens` order; the first is the main display (menu bar).
    ///   - pointer: the display under the pointer, if known.
    static func targets(_ screens: [ScreenInfo], settings: DisplaySettings, pointer: CGDirectDisplayID?) -> [ScreenInfo] {
        guard let main = screens.first else { return [] }
        switch settings.placement {
        case .all:
            return screens
        case .pointer:
            return [screens.first { $0.id == pointer } ?? main]
        case .builtIn:
            if let builtIn = screens.first(where: \.isBuiltIn) { return [builtIn] }
            // The lid is closed (or this Mac has no built-in display).
            return settings.externalWhenLidClosed ? [main] : []
        }
    }

    /// Pairs the islands that exist with the displays that should have one. An island keeps its
    /// display if that display is still a target; one whose display went away moves to a free
    /// target, the open (pinned) ones first, so a pinned island survives an unplug with its state.
    /// Returns island → display; islands left out are closed, displays left over get new ones.
    static func assign<Island: Hashable>(_ current: [Island: CGDirectDisplayID], open: Set<Island>,
                                         to targets: [CGDirectDisplayID]) -> [Island: CGDirectDisplayID] {
        var result: [Island: CGDirectDisplayID] = [:]
        var free = targets
        for (island, display) in current where free.contains(display) {
            result[island] = display
            free.removeAll { $0 == display }
        }
        let homeless = current.keys.filter { result[$0] == nil }
            .sorted { open.contains($0) && !open.contains($1) }
        for island in homeless {
            guard let display = free.first else {
                // No free display: an open island takes over one held by a closed island.
                if open.contains(island), let (taken, display) = result.first(where: { !open.contains($0.key) }) {
                    result[taken] = nil
                    result[island] = display
                }
                continue
            }
            result[island] = display
            free.removeFirst()
        }
        return result
    }

    /// The display under a point (AppKit coordinates), or nil if it is between displays.
    static func display(at point: CGPoint, in screens: [ScreenInfo]) -> CGDirectDisplayID? {
        screens.first { $0.frame.contains(point) }?.id
    }
}
