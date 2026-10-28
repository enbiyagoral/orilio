import AppKit

/// Puts an island on each display that should have one and keeps it there: displays coming and
/// going, the pointer moving between them, fullscreen apps, Spaces, sleep. Owns every
/// display-related observer; the window controllers only lay out their own window.
///
/// Observers (all event-driven):
/// - `didChangeScreenParameters`, `UserDefaults.didChange`: for the app's lifetime.
/// - `NSWorkspace.didWake`, "screen is unlocked": for the app's lifetime.
/// - `NSWorkspace.activeSpaceDidChange`, `didActivateApplication`: for the app's lifetime; each
///   re-checks for fullscreen apps once, and once more 0.6 s later (the fullscreen animation).
/// - A global `mouseMoved` monitor: only while "Display with the pointer" has more than one
///   display to choose from, or a fullscreen display uses "Reveal from the top edge". Removed as
///   soon as neither holds. It needs no permission (mouse events only).
@MainActor
final class IslandPositioner {
    private let primary: IslandModel
    private let makeModel: () -> IslandModel
    private(set) var islands: [ObjectIdentifier: IslandWindowController] = [:]
    private(set) var settings: DisplaySettings
    private var screens: [ScreenInfo] = []
    private var pointerDisplay: CGDirectDisplayID?
    private var fullscreenDisplays: Set<CGDirectDisplayID> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pointerMonitor: Any?
    private var lastPointerCheck: TimeInterval = 0
    private var edgeDwell: Task<Void, Never>?
    private var fullscreenRecheck: Task<Void, Never>?

    /// The pointer must rest at the top edge this long before a hidden island slides in.
    static let revealDwell: Duration = .milliseconds(300)
    /// Pointer events are looked at no more often than this.
    static let pointerThrottle: TimeInterval = 0.15

    init(primary: IslandModel, makeModel: @escaping () -> IslandModel) {
        self.primary = primary
        self.makeModel = makeModel
        settings = DisplaySettings(.standard)
        observe()
        update()
    }

    // MARK: Placement

    /// Re-resolves which displays get an island and moves, opens or closes windows to match.
    func update() {
        screens = NSScreen.screens.compactMap(ScreenInfo.init)
        if pointerDisplay == nil || !screens.contains(where: { $0.id == pointerDisplay }) {
            pointerDisplay = ScreenResolver.display(at: NSEvent.mouseLocation, in: screens)
        }
        let targets = ScreenResolver.targets(screens, settings: settings, pointer: pointerDisplay)
        let current = islands.mapValues(\.screen.id)
        let open = Set(islands.filter { $0.value.model.state.isOpen }.keys)
        let assignment = ScreenResolver.assign(current, open: open, to: targets.map(\.id))

        for (key, island) in islands where assignment[key] == nil {
            island.close()
            islands[key] = nil
        }
        for (key, display) in assignment {
            if let screen = screens.first(where: { $0.id == display }) { islands[key]?.move(to: screen) }
        }
        let covered = Set(assignment.values)
        for target in targets where !covered.contains(target.id) {
            // The first island uses the app's model; others share its modules and music.
            let model = islands.values.contains { $0.model === primary } ? makeModel() : primary
            model.hoverOpens = primary.hoverOpens
            let island = IslandWindowController(model: model, screen: target, allSpaces: settings.allSpaces)
            islands[ObjectIdentifier(island)] = island
        }
        for island in islands.values {
            island.reposition()
            island.setFullscreen(fullscreenDisplays.contains(island.screen.id) ? settings.fullscreen : nil)
        }
        updatePointerMonitor()
    }

    private func settingsChanged() {
        let new = DisplaySettings(.standard)
        let defaults = UserDefaults.standard
        let hoverOpens = defaults.object(forKey: SettingsKeys.openOnHover) as? Bool ?? true
        islands.values.forEach { $0.model.hoverOpens = hoverOpens }
        primary.hoverOpens = hoverOpens
        let showDemo = defaults.bool(forKey: SettingsKeys.showDemoSource)
        Task { [demo = primary.demo] in await demo.setEnabled(showDemo) }
        guard new != settings else { return islands.values.forEach { $0.reposition() } }
        if new.allSpaces != settings.allSpaces { islands.values.forEach { $0.setSpaces(all: new.allSpaces) } }
        settings = new
        update()
    }

    // MARK: Fullscreen

    private func recheckFullscreen() {
        let found = FullscreenDetector.displays(in: screens)
        guard found != fullscreenDisplays else { return }
        fullscreenDisplays = found
        for island in islands.values {
            island.setFullscreen(found.contains(island.screen.id) ? settings.fullscreen : nil)
        }
        updatePointerMonitor()
    }

    private func spaceOrAppChanged() {
        recheckFullscreen()
        fullscreenRecheck?.cancel()
        fullscreenRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600)) // entering fullscreen animates
            guard !Task.isCancelled else { return }
            self?.recheckFullscreen()
        }
    }

    // MARK: Pointer

    private var needsPointer: Bool {
        (settings.placement == .pointer && screens.count > 1)
            || (settings.fullscreen == .reveal && !fullscreenDisplays.isEmpty)
    }

    private func updatePointerMonitor() {
        if needsPointer, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
            }
        } else if !needsPointer, let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
            edgeDwell?.cancel()
        }
    }

    /// A cheap check per (throttled) event: has the pointer changed displays, or reached the top
    /// edge of a fullscreen one?
    private func pointerMoved(_ point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerCheck >= Self.pointerThrottle else { return }
        lastPointerCheck = now
        guard let display = ScreenResolver.display(at: point, in: screens),
              let screen = screens.first(where: { $0.id == display }) else { return }

        // Follow the pointer, but never pull an open island out from under the user.
        if settings.placement == .pointer, display != pointerDisplay,
           !islands.values.contains(where: { $0.model.state.isOpen }) {
            pointerDisplay = display
            update()
        }

        guard settings.fullscreen == .reveal, fullscreenDisplays.contains(display),
              let island = islands.values.first(where: { $0.screen.id == display }) else {
            edgeDwell?.cancel()
            return
        }
        if point.y >= screen.frame.maxY - 2 {
            guard edgeDwell == nil || edgeDwell?.isCancelled == true else { return }
            edgeDwell = Task { [weak island] in
                try? await Task.sleep(for: Self.revealDwell)
                guard !Task.isCancelled else { return }
                island?.reveal()
            }
        } else {
            edgeDwell?.cancel()
            edgeDwell = nil
            // Well below the island: let it go again.
            if island.isRevealedOrOpen, point.y < screen.frame.maxY - 80 { island.conceal() }
        }
    }

    // MARK: Observers

    private func observe() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // Defaults and screen changes are handled on the next turn of the run loop, never inline:
        // AppKit can post them from inside SwiftUI's layout, and moving windows there aborts it.
        add(center, NSApplication.didChangeScreenParametersNotification) { $0.update() }
        add(center, UserDefaults.didChangeNotification) { $0.settingsChanged() }
        add(workspace, NSWorkspace.didWakeNotification) { positioner in
            positioner.update() // displays may have changed while asleep
            positioner.primary.media.systemDidWake() // sessions missed their heartbeats
        }
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            $0.primary.media.systemDidWake()
        }
        add(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.spaceOrAppChanged() }
        add(workspace, NSWorkspace.didActivateApplicationNotification) { $0.spaceOrAppChanged() }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (IslandPositioner) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { handler(self) } }
        }
        observers.append((center, token))
    }
}

/// Which displays show a fullscreen app right now. Public window metadata only (bounds, layer,
/// owner); no window titles or contents, so no Screen Recording permission.
enum FullscreenDetector {
    struct WindowInfo: Equatable {
        let bounds: CGRect // window-server coordinates: origin at the top left of the main display
        let layer: Int
        let ownerPID: pid_t
    }

    @MainActor static func displays(in screens: [ScreenInfo]) -> Set<CGDirectDisplayID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let windows = list.compactMap { info -> WindowInfo? in
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return WindowInfo(bounds: bounds, layer: layer, ownerPID: pid)
        }
        return displays(windows: windows, screens: screens, me: getpid())
    }

    /// A display shows a fullscreen app when another app has a normal-level window exactly covering
    /// it (menu bar included; a zoomed window stops below the menu bar). Pure.
    static func displays(windows: [WindowInfo], screens: [ScreenInfo], me: pid_t) -> Set<CGDirectDisplayID> {
        guard let mainHeight = screens.first?.frame.height else { return [] }
        var result = Set<CGDirectDisplayID>()
        for screen in screens {
            let cgFrame = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                                 width: screen.frame.width, height: screen.frame.height)
            if windows.contains(where: { $0.layer == 0 && $0.ownerPID != me && $0.bounds == cgFrame }) {
                result.insert(screen.id)
            }
        }
        return result
    }
}
