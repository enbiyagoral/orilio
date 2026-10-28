import AppKit
import Quartz
import SwiftUI

/// Where the island sits on one screen, in AppKit screen coordinates (origin bottom-left).
struct IslandGeometry: Equatable {
    /// Height of the hardware notch, or of the menu bar band on screens without one.
    /// Expanded content starts below this so nothing hides behind the notch.
    var topInset: CGFloat
    /// 0 on screens without a hardware notch.
    var notchWidth: CGFloat
    var centerX: CGFloat
    var screenTop: CGFloat
    /// Height of the screen's usable area (below the menu bar, above the Dock).
    var usableHeight: CGFloat = .greatestFiniteMagnitude
    /// Pixels per point; positions snap to this display's pixel grid (1x and 2x screens mix).
    var scale: CGFloat = 2
    /// Settings › Appearance › Panel size: the open panel's width (560, 700 or 820 pt). The content
    /// height scales with it; the collapsed island doesn't change.
    var panelWidth: CGFloat = IslandGeometry.fullWidth

    static let pillWidth: CGFloat = 220     // fits a mini cover + a short title in the menu bar band
    // The M3 hub design: a 700 × 304 panel whose 38 pt header row shares the notch's row (tabs to
    // its left, pin and close to its right), with a 266 pt content area below.
    static let fullWidth: CGFloat = 700
    static let headerHeight: CGFloat = 38
    static let contentHeight: CGFloat = 266
    /// The collapsed island while a meeting is about to start.
    static let dropTargetWidth: CGFloat = 360
    static let dropTargetHeight: CGFloat = 92 // a 68pt drop zone + 12pt padding
    /// The Screenshots grid: about four rows of thumbnails, never taller than the usable screen.
    static let tallHeight: CGFloat = 412

    /// Concave "shoulders" that blend the open island into the top edge of the screen.
    static let earRadius: CGFloat = 10
    /// Room around the open island for its shadow; also a slightly forgiving hover zone.
    static let shadowMargin: CGFloat = 24

    static let fallback = IslandGeometry(topInset: 24, notchWidth: 0, centerX: 0, screenTop: 0)

    var hasNotch: Bool { notchWidth > 0 }

    /// On a notched screen the collapsed island is exactly the notch, so it never covers menu bar items.
    var collapsed: CGSize {
        CGSize(width: hasNotch ? notchWidth : Self.pillWidth, height: topInset)
    }

    /// Click: the full controller.
    var full: CGSize {
        CGSize(width: panelWidth, height: max(topInset, Self.headerHeight) + (Self.contentHeight * panelWidth / Self.fullWidth).rounded())
    }

    /// A drag over the island: enough room for a clear drop zone, no more.
    var dropTarget: CGSize {
        CGSize(width: max(Self.dropTargetWidth, collapsed.width), height: topInset + Self.dropTargetHeight)
    }

    /// The full panel grown for the screenshot grid, capped so it never runs off the screen.
    var tall: CGSize {
        let room = usableHeight + topInset - Self.shadowMargin * 2
        return CGSize(width: panelWidth, height: min(Self.tallHeight * panelWidth / Self.fullWidth, max(full.height, room)))
    }

    func size(for state: IslandState, tall wantsTall: Bool = false, collapsedWidth: CGFloat? = nil) -> CGSize {
        switch state {
        case .collapsed: CGSize(width: max(collapsed.width, collapsedWidth ?? 0), height: collapsed.height)
        case .expanded, .pinned: wantsTall ? tall : full
        case .dropTarget: dropTarget
        }
    }

    /// Collapsed: exactly the island. Open: the island plus ears and shadow room.
    func windowFrame(for state: IslandState, tall: Bool = false, collapsedWidth: CGFloat? = nil) -> CGRect {
        var size = size(for: state, tall: tall, collapsedWidth: collapsedWidth)
        if state.isOpen {
            size.width += 2 * (Self.earRadius + Self.shadowMargin)
            size.height += Self.shadowMargin
        }
        let x = ((centerX - size.width / 2) * scale).rounded() / scale
        return CGRect(x: x, y: screenTop - size.height, width: size.width, height: size.height)
    }

    /// `auxLeftWidth`/`auxRightWidth` are the menu bar areas either side of the notch
    /// (`NSScreen.auxiliaryTopLeftArea`/`…RightArea`); the notch is what lies between them.
    static func make(screenFrame: CGRect, safeAreaTop: CGFloat,
                     auxLeftWidth: CGFloat?, auxRightWidth: CGFloat?,
                     menuBarHeight: CGFloat, scale: CGFloat = 2) -> IslandGeometry {
        if safeAreaTop > 0, let left = auxLeftWidth, let right = auxRightWidth {
            let notch = screenFrame.width - left - right
            return IslandGeometry(topInset: safeAreaTop, notchWidth: notch,
                                  centerX: screenFrame.minX + left + notch / 2, screenTop: screenFrame.maxY, scale: scale)
        }
        return IslandGeometry(topInset: menuBarHeight, notchWidth: 0,
                              centerX: screenFrame.midX, screenTop: screenFrame.maxY, scale: scale)
    }
}

/// Non-activating, so hovering or clicking controls never pulls focus from the user's app.
/// Only pinning activates it (see `IslandWindowController.apply`).
final class IslandPanel: NSPanel {
    var onEscape: (() -> Void)?
    /// Keys for the visible content (the shelf's Space, Delete, ⌘C). Returns true if handled.
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !event.modifierFlags.isDisjoint(with: [.command, .control]), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // Quick Look finds its data source through the key window's responder chain. AppKit calls
    // these on the main thread; the informal protocol just isn't annotated for it.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLook.source
            panel.delegate = QuickLook.source
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

final class IslandHostingView: NSHostingView<IslandView> {
    var onHover: ((Bool) -> Void)?
    /// Drag destination callbacks. Dragging never activates Orilio, so focus stays where it was.
    var onDragEntered: ((_ valid: Bool) -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: ((_ content: DropContent, _ sequence: Int) -> Bool)?
    private var hoverArea: NSTrackingArea?
    private var dragIsValid = false

    required init(rootView: IslandView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(DropContent.observedTypes)
        // .activeAlways: the panel is never the active app's window, so the default would get no events.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover?(false) }
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragIsValid = DropContent.isSupported(sender.draggingPasteboard.types ?? [])
        onDragEntered?(dragIsValid)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    /// Also called when a drop over the island was refused; without this the drop zone would stay open.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragIsValid }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(DropContent.read(sender.draggingPasteboard), sender.draggingSequenceNumber) ?? false
    }

    /// "Link" for the user's own files (the shelf only points at them); "copy" for promises and
    /// image data, which Orilio receives into its own folder.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard dragIsValid else { return [] } // shows the not-allowed cursor
        let mask = sender.draggingSourceOperationMask
        let isFile = sender.draggingPasteboard.types?.contains(.fileURL) == true
        let order: [NSDragOperation] = isFile ? [.link, .copy, .generic] : [.copy, .generic]
        for preferred in order where mask.contains(preferred) { return preferred }
        return isFile ? .link : .copy
    }
}

@MainActor
final class IslandWindowController {
    let model: IslandModel
    private let panel: IslandPanel
    private var shrinkTask: Task<Void, Never>?
    /// Watches for clicks outside the island while the full controller is open. Mouse monitors
    /// need no permission; it exists only while pinned.
    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var widthTask: Task<Void, Never>?
    /// Where the last outside press started, to tell a click from the start of a drag.
    private var outsidePress: NSPoint?

    /// The display this island is on (assigned by `IslandPositioner`).
    private(set) var screen: ScreenInfo
    /// Set while the display shows a fullscreen app; nil otherwise.
    private(set) var fullscreen: DisplaySettings.Fullscreen?
    /// "Reveal from the top edge": the pointer has brought the island in.
    private var revealed = false
    private var observers: [NSObjectProtocol] = []

    init(model: IslandModel, screen: ScreenInfo, allSpaces: Bool) {
        self.model = model
        self.screen = screen
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        IslandWindowPolicy.apply(to: panel, allSpaces: allSpaces)

        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = [] // the controller owns the frame; don't let SwiftUI resize the panel
        host.onHover = { [weak model] in model?.hover($0) }
        host.onDragEntered = { [weak model] in model?.dragEntered(valid: $0) }
        host.onDragExited = { [weak model] in model?.dragExited() }
        host.onDrop = { [weak model] in model?.dropped($0, sequence: $1) ?? false }
        panel.contentView = host
        panel.onEscape = { [weak model] in model?.dismiss() }
        panel.onKey = { [weak model] event in
            guard let model, model.state == .pinned else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌃⇥ and ⌃⇧⇥ move between modules, as between tabs anywhere on the Mac.
            if event.keyCode == 48, flags.contains(.control) {
                model.selectAdjacentTab(flags.contains(.shift) ? -1 : 1)
                return true
            }
            if model.tab == .clipboard { return model.clipboard.handleKey(keyCode: event.keyCode, command: flags == .command) }
            guard model.tab == .shelf else { return false }
            switch model.shelfSection {
            case .files: return model.shelf.handleKey(keyCode: event.keyCode, command: flags == .command)
            case .screenshots: return model.library.handleKey(keyCode: event.keyCode, command: flags == .command)
            }
        }
        model.onWillChangeState = { [weak self] in self?.apply($0) }
        // A click anywhere in the hover panel keeps it: the user is now working in it (typing in a
        // note must not end when the pointer drifts off). The click itself still goes through.
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.panel, self.model.state == .expanded { self.model.keepOpen() }
            }
            return event
        }

        // Another app came forward (including the source the user just jumped to): put the controller away.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { if model?.state == .pinned { model?.dismiss() } }
        })

        reposition()
        followLiveWidth()
        panel.orderFrontRegardless()
    }

    /// Places the island on its display. Never activates the app, so the user's focus stays put.
    func reposition() {
        var geometry = screen.geometry
        geometry.panelWidth = PreferencesStore.shared.value.panelSize.width
        if geometry != model.geometry { model.geometry = geometry }
        panel.setFrame(geometry.windowFrame(for: model.state, tall: model.wantsTallPanel,
                                            collapsedWidth: model.liveCollapsedWidth), display: true)
    }

    /// To another display (pointer moved, a display was unplugged); the island's state goes with it.
    func move(to screen: ScreenInfo) {
        guard screen != self.screen else { return }
        self.screen = screen
        revealed = false
        reposition()
    }

    func setSpaces(all: Bool) { IslandWindowPolicy.apply(to: panel, allSpaces: all) }

    /// The display started or stopped showing a fullscreen app.
    func setFullscreen(_ mode: DisplaySettings.Fullscreen?) {
        guard mode != fullscreen else { return }
        fullscreen = mode
        revealed = false
        refreshVisibility()
    }

    /// The pointer rested at the top edge of a fullscreen display: slide the island in.
    func reveal() {
        guard fullscreen == .reveal, !revealed else { return }
        revealed = true
        refreshVisibility(sliding: true)
    }

    /// The pointer left the top of the display: hide again, unless the user opened the island.
    func conceal() {
        guard revealed, !model.state.isOpen else { return }
        revealed = false
        refreshVisibility()
    }

    var isRevealedOrOpen: Bool { revealed || model.state.isOpen }

    /// Fullscreen "Hide" waits with everything except a meeting starting now; "Reveal" shows the
    /// island while the pointer brought it in (or while it is open).
    private var shouldShow: Bool {
        let meetingNow: Bool = {
            guard case .meeting(let event)? = model.earLayout.primary?.payload else { return false }
            return MeetingEar.started(event, now: Date())
        }()
        switch fullscreen {
        case nil, .show?: return true
        case .hide?: return meetingNow || model.state.isOpen
        case .reveal?: return revealed || model.state.isOpen || meetingNow
        }
    }

    private func refreshVisibility(sliding: Bool = false) {
        let show = shouldShow
        guard show != panel.isVisible else { return }
        if !show { return panel.orderOut(nil) }
        reposition()
        guard sliding, !Theme.current.reducesMotion else { return panel.orderFrontRegardless() }
        // Slide down from above the top edge.
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: target.height), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// Takes the window down for good (its display went away, or the setting changed).
    func close() {
        widthTask?.cancel()
        shrinkTask?.cancel()
        watchOutsideClicks(false)
        if let insideClickMonitor { NSEvent.removeMonitor(insideClickMonitor) }
        insideClickMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model.onWillChangeState = nil
        panel.orderOut(nil)
    }

    private func apply(_ state: IslandState) {
        shrinkTask?.cancel()
        watchOutsideClicks(state == .pinned)
        Task { @MainActor [weak self] in self?.refreshVisibility() } // once the new state is set

        if state == .pinned, model.pinTakesFocus {
            // Pinning is an explicit click, so taking the keyboard (for Esc) is intended.
            // The app has no other windows, so activating it raises nothing else.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        } else if !state.isOpen, NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            // Give the keyboard back to the app the user was in (skipped while Settings is open).
            NSApp.deactivate()
        }

        // Sized for the state being entered (the model still reports the old one at this point).
        let target = model.geometry.windowFrame(for: state, tall: model.isTall(state), collapsedWidth: model.liveCollapsedWidth)
        if target.width >= panel.frame.width, target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
            panel.contentView?.layoutSubtreeIfNeeded() // settle the current island in the bigger window
        } else {
            // Keep the window large until the SwiftUI shrink animation has finished, then shrink it
            // so the empty area stops catching clicks.
            let delay = Theme.current.reducesMotion ? 0 : IslandModel.closeDuration
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.model.state == state else { return }
                self.panel.setFrame(target, display: true)
            }
        }
    }

    /// The collapsed island widens for a live meeting and narrows again; follow it without a timer.
    private func followLiveWidth() {
        withObservationTracking { _ = (model.liveCollapsedWidth, model.earLayout) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.model.state.isOpen { self.resizeCollapsed() }
                self.refreshVisibility() // a meeting starting now shows even over a fullscreen app
                self.followLiveWidth()
            }
        }
    }

    /// Wider at once (the shape springs out inside the window); narrower only after the spring,
    /// so the shrinking shape isn't cut off.
    private func resizeCollapsed() {
        widthTask?.cancel()
        let target = model.geometry.windowFrame(for: .collapsed, collapsedWidth: model.liveCollapsedWidth)
        guard target.width < panel.frame.width else { return reposition() }
        let delay = Theme.current.reducesMotion ? 0 : 0.44
        widthTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.model.state.isOpen else { return }
            self.reposition()
        }
    }

    private func watchOutsideClicks(_ on: Bool) {
        if on, outsideClickMonitor == nil {
            // Global monitors see only events in other apps, so everything here is outside the island.
            // A *click* (press and release in place) closes the panel. A press that turns into a drag
            // doesn't: the user may be bringing a file from Finder to the open shelf.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.outsideEvent(event.type, at: NSEvent.mouseLocation) }
            }
        } else if !on, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
            outsidePress = nil
        }
    }

    private func outsideEvent(_ type: NSEvent.EventType, at point: NSPoint) {
        switch type {
        case .leftMouseDown:
            outsidePress = point
        case .leftMouseUp:
            guard let start = outsidePress else { return }
            outsidePress = nil
            if Self.isClick(from: start, to: point) { model.dismiss() }
        default: // a right click is always a click
            model.dismiss()
        }
    }

    /// A press and release within a few points is a click; more is a drag.
    static func isClick(from start: NSPoint, to end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) <= 4
    }
}

/// The island window's level and Space behavior, decided in one place.
@MainActor
enum IslandWindowPolicy {
    static func apply(to panel: NSPanel, allSpaces: Bool) {
        // Just above the menu bar (.mainMenu), so the island can sit inside its band, and below
        // system alerts and the screen saver.
        panel.level = .statusBar
        var behavior: NSWindow.CollectionBehavior = [
            .stationary,          // stays put while Spaces slide and in Mission Control
            .fullScreenAuxiliary, // may appear over a fullscreen app (the fullscreen setting decides when)
            .ignoresCycle,        // never a stop for ⌘` or window cycling
        ]
        // On every Space, and beside Stage Manager's strip; otherwise it stays on the Space it opened on.
        if allSpaces { behavior.insert(.canJoinAllSpaces) }
        panel.collectionBehavior = behavior
    }
}
