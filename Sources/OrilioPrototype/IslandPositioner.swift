// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

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
/// - Global `leftMouseDown`/`Dragged`/`Up` monitors: for the app's lifetime, to notice a file drag
///   starting anywhere (the drag pasteboard's change count moves). One cheap read per drag event,
///   throttled, and only until the drag is recognized. Mouse monitors need no permission.
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
    private var dragMonitor: Any?
    private var dragWatch = DragWatch()

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
        followFocusEnd()
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
        for island in islands.values { island.reposition() }
        // Also at launch and when displays change, not only on a Space or app switch: Orilio may
        // start while a fullscreen app is already in front.
        fullscreenDisplays = FullscreenDetector.displays(in: screens)
        for island in islands.values {
            island.setFullscreen(fullscreenDisplays.contains(island.screen.id) ? settings.fullscreen : nil)
        }
        updatePointerMonitor()
    }

    private func settingsChanged() {
        let new = DisplaySettings(.standard)
        let prefs = PreferencesStore.shared.value
        for model in islands.values.map(\.model) + [primary] {
            model.hoverOpens = prefs.openOnHover
            model.hoverDelay = .milliseconds(prefs.hoverDelay)
        }
        guard new != settings else { return islands.values.forEach { $0.reposition() } }
        if new.allSpaces != settings.allSpaces { islands.values.forEach { $0.setSpaces(all: new.allSpaces) } }
        settings = new
        update()
    }

    /// The global shortcut: closes whatever island is open, else opens the one on the pointer's
    /// display (it shows even over a fullscreen app while open).
    func toggle() {
        let open = islands.values.filter { $0.model.state.isOpen }
        guard open.isEmpty else { return open.forEach { $0.model.dismiss() } }
        let display = ScreenResolver.display(at: NSEvent.mouseLocation, in: screens)
        (islands.values.first { $0.screen.id == display } ?? islands.values.first)?.model.openFromKeyboard()
    }

    /// A shortcut that opens a module: the island on the pointer's display opens to it.
    func open(_ tab: IslandTab) {
        let display = ScreenResolver.display(at: NSEvent.mouseLocation, in: screens)
        guard let model = (islands.values.first { $0.screen.id == display } ?? islands.values.first)?.model,
              model.modules.isVisible(tab) else { return }
        model.tab = tab
        model.openFromKeyboard()
    }

    /// Whether the display under the pointer shows a fullscreen app (the startup hello stays away then).
    var pointerDisplayIsFullscreen: Bool {
        ScreenResolver.display(at: NSEvent.mouseLocation, in: screens).map(fullscreenDisplays.contains) ?? false
    }

    // MARK: Fullscreen

    private func recheckFullscreen() {
        defer { deliverFocusEnd() } // a card that waited for the fullscreen app to go
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

    // MARK: Focus end

    /// The session-done card waits while the pointer's display hides the island for a fullscreen
    /// app, or a meeting is showing; it opens as soon as neither holds.
    private var focusEndWaiting = false
    private var lastFinished: FocusModule.Finished?

    private func followFocusEnd() {
        withObservationTracking { _ = (primary.focus.finished, primary.meetingSoon) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let finished = self.primary.focus.finished
                if finished != self.lastFinished {
                    self.lastFinished = finished
                    self.focusEndWaiting = finished != nil
                }
                self.deliverFocusEnd()
                self.followFocusEnd()
            }
        }
    }

    private func deliverFocusEnd() {
        guard focusEndWaiting, primary.focus.finished != nil else { return focusEndWaiting = false }
        let display = ScreenResolver.display(at: NSEvent.mouseLocation, in: screens)
        guard let island = islands.values.first(where: { $0.screen.id == display }) ?? islands.values.first,
              FocusEndPolicy.canOpen(fullscreen: island.fullscreen, meetingShowing: island.model.meetingSoon != nil,
                                     islandOpenElsewhere: island.model.state.isOpen && island.model.tab != .focus) else { return }
        focusEndWaiting = false
        island.model.presentFocusEnd()
    }

    // MARK: Drags from other apps

    /// A file drag started in another app: every collapsed island shows "Drop on Shelf" until the
    /// button comes up (the drop itself goes through the island's drag destination).
    private func mouse(_ type: NSEvent.EventType) {
        switch dragWatch.event(type, changeCount: { NSPasteboard(name: .drag).changeCount }, now: ProcessInfo.processInfo.systemUptime) {
        case .started:
            let types = NSPasteboard(name: .drag).types ?? []
            guard DropContent.isSupported(types), primary.modules.isVisible(.shelf) else { return }
            setDropHint(true)
        case .ended: setDropHint(false)
        case nil: break
        }
    }

    private func setDropHint(_ on: Bool) {
        for model in islands.values.map(\.model) where model.dropHint != on { model.dropHint = on }
        guard on, dropHintEnd == nil else { return }
        // The button-up of a drag doesn't always reach a global monitor (a drop on Orilio's own
        // window, for one); while the hint shows, check the button now and then.
        dropHintEnd = Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
            self?.dropHintEnd = nil
            self?.setDropHint(false)
        }
    }

    private var dropHintEnd: Task<Void, Never>?

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
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.mouse(type) }
        }
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

/// Tells a drag from a plain press: the drag pasteboard's change count moves once a drag session
/// begins. Pure, so the order of events is tested.
struct DragWatch {
    enum Change: Equatable { case started, ended }

    private var countAtPress: Int?
    private var recognized = false
    private var lastCheck: TimeInterval = -.infinity
    static let throttle: TimeInterval = 0.08

    mutating func event(_ type: NSEvent.EventType, changeCount: () -> Int, now: TimeInterval) -> Change? {
        switch type {
        case .leftMouseDown:
            countAtPress = changeCount()
            recognized = false
            return nil
        case .leftMouseDragged:
            guard !recognized, let countAtPress, now - lastCheck >= Self.throttle else { return nil }
            lastCheck = now
            guard changeCount() != countAtPress else { return nil }
            recognized = true
            return .started
        case .leftMouseUp:
            defer { recognized = false; countAtPress = nil }
            return recognized ? .ended : nil
        default:
            return nil
        }
    }
}

/// When the focus card may open the island by itself. Pure.
enum FocusEndPolicy {
    static func canOpen(fullscreen: DisplaySettings.Fullscreen?, meetingShowing: Bool, islandOpenElsewhere: Bool) -> Bool {
        fullscreen != .hide && !meetingShowing && !islandOpenElsewhere
    }
}
