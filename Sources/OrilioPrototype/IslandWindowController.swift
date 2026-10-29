// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Quartz
import SwiftUI

enum IslandLayout {
    case notch, floating

    /// Where the island is, in words: "the notch", or "the island" on a display without one.
    var place: String { self == .notch ? String(localized: "the notch") : String(localized: "the island") }
}

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
    /// The display's name ("Studio Display"), shown in the floating panel's tab row.
    var displayName = ""

    static let pillWidth: CGFloat = 220     // fits a mini cover + a short title in the menu bar band
    // The M3 hub design: a 700 × 304 panel whose 38 pt header row shares the notch's row (tabs to
    // its left, pin and close to its right), with a 266 pt content area below.
    static let fullWidth: CGFloat = 700
    static let headerHeight: CGFloat = 38
    static let contentHeight: CGFloat = 266
    /// A drag over the island (the M5 Moments design): a 126 pt drop zone and 14 pt padding.
    static let dropTargetHeight: CGFloat = 140
    /// A file drag anywhere on screen: the collapsed island glows and grows this much ("Drop on Shelf").
    static let dropHintWidth: CGFloat = 240
    static let dropHintGrowth: CGFloat = 12
    /// The Screenshots grid: about four rows of thumbnails, never taller than the usable screen.
    static let tallHeight: CGFloat = 412

    /// Concave "shoulders" that blend the open island into the top edge of the screen.
    static let earRadius: CGFloat = 10
    /// Room around the open island for its shadow; also a slightly forgiving hover zone.
    static let shadowMargin: CGFloat = 24

    static let fallback = IslandGeometry(topInset: 24, notchWidth: 0, centerX: 0, screenTop: 0)

    var hasNotch: Bool { notchWidth > 0 }

    /// How the island sits on this display (the M5 no-notch design): under the notch with ears, or
    /// floating below the top with all four corners rounded and a hairline edge. Decided here once;
    /// views read it from the environment.
    var layout: IslandLayout { hasNotch ? .notch : .floating }
    /// Floating: the open panel starts this far below the menu bar.
    static let floatingGap: CGFloat = 6
    /// Floating: the collapsed capsule sits this far inside the menu bar band, top and bottom.
    static let pillInset: CGFloat = 3
    static let floatingRadius: CGFloat = 28
    /// Where the open panel's shape starts inside the window.
    var openTop: CGFloat { layout == .floating ? topInset + Self.floatingGap : 0 }
    /// The open panel's first row (tabs, pin, close): it shares the notch's row, or is the panel's own.
    var headerRow: CGFloat { layout == .floating ? Self.headerHeight : max(topInset, Self.headerHeight) }

    /// On a notched screen the collapsed island is exactly the notch, so it never covers menu bar items.
    var collapsed: CGSize {
        CGSize(width: hasNotch ? notchWidth : Self.pillWidth, height: topInset)
    }

    /// Click: the full controller.
    var full: CGSize {
        CGSize(width: panelWidth, height: headerRow + (Self.contentHeight * panelWidth / Self.fullWidth).rounded())
    }

    /// A drag over the island: the panel's width, enough height for a clear drop zone, no more.
    var dropTarget: CGSize {
        CGSize(width: max(panelWidth, collapsed.width), height: (layout == .floating ? 0 : topInset) + Self.dropTargetHeight)
    }

    /// The full panel grown for the screenshot grid, capped so it never runs off the screen.
    var tall: CGSize {
        let room = usableHeight + topInset - Self.shadowMargin * 2
        return CGSize(width: panelWidth, height: min(Self.tallHeight * panelWidth / Self.fullWidth, max(full.height, room)))
    }

    /// `panel` replaces the open size for a module with its own (the camera mirror).
    /// The island's size in its window; a floating open panel also counts the room above it.
    func size(for state: IslandState, tall wantsTall: Bool = false, collapsedWidth: CGFloat? = nil, panel: CGSize? = nil,
              dropHint: Bool = false) -> CGSize {
        var size = panelSize(for: state, tall: wantsTall, collapsedWidth: collapsedWidth, panel: panel, dropHint: dropHint)
        if state.isOpen { size.height += openTop }
        return size
    }

    private func panelSize(for state: IslandState, tall wantsTall: Bool, collapsedWidth: CGFloat?, panel: CGSize?,
                           dropHint: Bool) -> CGSize {
        switch state {
        case .collapsed where dropHint:
            CGSize(width: max(collapsed.width, collapsedWidth ?? 0, Self.dropHintWidth), height: collapsed.height + Self.dropHintGrowth)
        case .collapsed: CGSize(width: max(collapsed.width, collapsedWidth ?? 0), height: collapsed.height)
        case .expanded, .pinned: panel ?? (wantsTall ? tall : full)
        case .dropTarget: dropTarget
        }
    }

    /// Collapsed: exactly the island. Open: the island plus ears and shadow room.
    func windowFrame(for state: IslandState, tall: Bool = false, collapsedWidth: CGFloat? = nil, panel: CGSize? = nil,
                     dropHint: Bool = false) -> CGRect {
        var size = size(for: state, tall: tall, collapsedWidth: collapsedWidth, panel: panel, dropHint: dropHint)
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
    var onDragEntered: ((_ valid: Bool, _ count: Int) -> Void)?
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
        let count = sender.draggingPasteboard.pasteboardItems?.count ?? 1
        if dragIsValid { sender.numberOfValidItemsForDrop = count } // the badge on the dragged files
        onDragEntered?(dragIsValid, count)
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
    private var keyMonitor: Any?
    private var swipeMonitor: Any?
    private var swipe = SwipeTracker()
    private var widthTask: Task<Void, Never>?
    /// Bumped by each move to another display, so only the latest one arrives.
    private var moveGeneration = 0
    /// Fading out on the old display: layout waits for `arrive()`, which lays out on the new one.
    private var moving = false
    private var hint: NSPanel?
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
        host.onDragEntered = { [weak model] in model?.dragEntered(valid: $0, count: $1) }
        host.onDragExited = { [weak model] in model?.dragExited() }
        host.onDrop = { [weak model] in model?.dropped($0, sequence: $1) ?? false }
        panel.contentView = host
        panel.onEscape = { [weak model] in
            guard let model else { return }
            // Esc first closes the Shelf's Quick Look, then the island.
            if model.tab == .shelf, model.shelf.previewing != nil { model.shelf.closePreview() } else { model.dismiss() }
        }
        panel.onKey = { [weak model] event in
            // What the island's router leaves: the Shelf's ⌘C, the Screenshots grid's keys.
            guard let model, model.state == .pinned, model.tab == .shelf else { return false }
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            switch model.shelfSection {
            case .files: return model.shelf.handleKey(keyCode: event.keyCode, command: command)
            case .screenshots: return model.library.handleKey(keyCode: event.keyCode, command: command)
            }
        }
        // The island's keys (the M5 Keyboard design), seen before the focused control so ↑↓ and ⏎
        // also work from the clipboard's search field. Local: only events already sent to Orilio's
        // own panel, which receives keys only while it is key (a click or a shortcut, never hover).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let window = event.windowNumber
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let key = event.type == .keyDown ? KeyPress(event) : nil
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, window == self.panel.windowNumber else { return false }
                guard let key else {
                    self.model.modifiersChanged(commandOnly: flags == .command)
                    return false
                }
                if self.model.onboarding != nil { return false } // the first-run flow keeps its own keys
                let editing: IslandKeyRouter.Editing = self.panel.firstResponder is NSTextView
                    ? (self.model.tab == .clipboard ? .search : .text) : .none
                return self.model.handleKey(key, editing: editing)
            }
            return consumed ? nil : event
        }
        // Two-finger swipes over the open island (scroll events reach it under the pointer, key or not).
        // Never consumed: vertical scrolling goes on to the lists as before.
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event } // trackpads only, no coasting
            let window = event.windowNumber, location = event.locationInWindow
            let phase: SwipeTracker.Phase = event.phase.contains(.began) ? .began
                : event.phase.contains(.changed) ? .changed
                : event.phase.contains(.ended) || event.phase.contains(.cancelled) ? .ended : .other
            // With natural scrolling the deltas already follow the fingers; otherwise they're reversed.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let dx = event.scrollingDeltaX * sign, dy = event.scrollingDeltaY * sign
            MainActor.assumeIsolated {
                guard let self, window == self.panel.windowNumber,
                      let direction = self.swipe.event(phase, dx: dx, dy: dy) else { return }
                let height = self.panel.contentView?.bounds.height ?? 0
                self.model.swiped(direction, at: CGPoint(x: location.x, y: height - location.y))
            }
            return event
        }
        model.onWillChangeState = { [weak self] in self?.apply($0) }
        // A click anywhere in the hover panel keeps it: the user is now working in it (typing in a
        // note must not end when the pointer drifts off). The click itself still goes through.
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return }
                self.model.pointerUsed() // the focus ring and hint bar are for keyboard use
                if self.model.state == .expanded { self.model.keepOpen() }
            }
            return event
        }

        // Another app came forward (including the source the user just jumped to): put the controller away.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { if model?.state == .pinned, model?.onboarding == nil { model?.dismiss() } }
        })

        reposition()
        followLiveWidth()
        panel.orderFrontRegardless()
    }

    /// Places the island on its display. Never activates the app, so the user's focus stays put.
    func reposition(animated: Bool = true) {
        guard !moving else { return }
        var geometry = screen.geometry
        geometry.panelWidth = PreferencesStore.shared.value.panelSize.width
        if geometry != model.geometry {
            // Moving to another display, the shape changes (ears ↔ floating pill) while it's out of sight.
            var transaction = Transaction()
            transaction.disablesAnimations = !animated
            withTransaction(transaction) { model.geometry = geometry }
        }
        panel.setFrame(geometry.windowFrame(for: model.state, tall: model.wantsTallPanel, collapsedWidth: model.liveCollapsedWidth,
                                            panel: model.customPanel(for: model.state), dropHint: model.dropHint), display: true)
    }

    /// To another display (pointer moved, a display was unplugged); the island's state goes with it.
    func move(to screen: ScreenInfo) {
        guard screen != self.screen else { return }
        let sameDisplay = screen.id == self.screen.id
        self.screen = screen
        if sameDisplay { return reposition() } // the Dock or the menu bar changed: no trip to make
        revealed = false
        guard panel.isVisible, !Theme.current.reducesMotion else { return reposition() }
        // A jump reads as a glitch: fade out where it was, then come down from the new display's top.
        moveGeneration += 1
        moving = true
        let generation = moveGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.moveGeneration else { return }
                self.arrive()
            }
        })
    }

    /// The second half of a move: on the new display, a short drop from its top edge.
    private func arrive() {
        moving = false
        reposition(animated: false)
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 0, dy: 10), display: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
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
        return Self.shows(fullscreen: fullscreen, revealed: revealed, open: model.state.isOpen, meetingNow: meetingNow)
    }

    /// Pure, for tests: whether the island is on screen.
    nonisolated static func shows(fullscreen: DisplaySettings.Fullscreen?, revealed: Bool, open: Bool, meetingNow: Bool) -> Bool {
        switch fullscreen {
        case nil, .show?: true
        case .hide?: meetingNow || open
        case .reveal?: revealed || open || meetingNow
        }
    }

    private func refreshVisibility(sliding: Bool = false) {
        let show = shouldShow
        guard show != panel.isVisible else { return }
        if !show { return panel.orderOut(nil) }
        panel.alphaValue = 1 // a move to another display may have been cut short while it faded
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model.onWillChangeState = nil
        hint?.orderOut(nil)
        hint = nil
        panel.orderOut(nil)
    }

    private func apply(_ state: IslandState) {
        shrinkTask?.cancel()
        watchOutsideClicks(state == .pinned)
        // Revealed over a fullscreen app and now closing with the pointer gone from the top: hide
        // again (no further pointer event may come to do it).
        if state == .collapsed, revealed, NSEvent.mouseLocation.y < screen.frame.maxY - 80 { revealed = false }
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
        let target = model.geometry.windowFrame(for: state, tall: model.isTall(state), collapsedWidth: model.liveCollapsedWidth,
                                                panel: model.customPanel(for: state), dropHint: model.dropHint)
        if target.width >= panel.frame.width, target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
            panel.contentView?.layoutSubtreeIfNeeded() // settle the current island in the bigger window
        } else {
            // Taller but narrower (or the reverse), as when the mirror opens: grow to hold both
            // sizes now, so nothing is cut off while the shape animates.
            let current = panel.frame
            if target.width > current.width || target.height > current.height {
                let width = max(current.width, target.width), height = max(current.height, target.height)
                let x = ((model.geometry.centerX - width / 2) * model.geometry.scale).rounded() / model.geometry.scale
                panel.setFrame(CGRect(x: x, y: model.geometry.screenTop - height, width: width, height: height), display: true)
                panel.contentView?.layoutSubtreeIfNeeded()
            }
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
        withObservationTracking { _ = (model.liveCollapsedWidth, model.earLayout, model.showsLivesHereHint, model.dropHint) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateHint()
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
        let target = model.geometry.windowFrame(for: .collapsed, collapsedWidth: model.liveCollapsedWidth, dropHint: model.dropHint)
        guard target.width < panel.frame.width || target.height < panel.frame.height else { return reposition() }
        let delay = Theme.current.reducesMotion ? 0 : 0.44
        widthTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.model.state.isOpen else { return }
            self.reposition()
        }
    }

    /// The one-time "Orilio lives here now" hint, centered under the island; it never takes clicks.
    private func updateHint() {
        if model.showsLivesHereHint {
            if hint == nil {
                let hint = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
                hint.isOpaque = false
                hint.backgroundColor = .clear
                hint.hasShadow = false
                hint.ignoresMouseEvents = true
                IslandWindowPolicy.apply(to: hint, allSpaces: true)
                hint.contentView = NSHostingView(rootView: LivesHereHint(layout: model.geometry.layout))
                self.hint = hint
            }
            guard let hint else { return }
            let geometry = model.geometry
            // The design: the arrow starts about 88 pt below the top of the screen.
            hint.setFrameOrigin(NSPoint(x: (geometry.centerX - 230).rounded(), y: geometry.screenTop - 88 - 120))
            // Already showing (the island's width or ears changed): it only follows, no fresh fade.
            guard !hint.isVisible else { return }
            hint.alphaValue = 0
            hint.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.current.reducesMotion ? 0 : 0.5
                hint.animator().alphaValue = 1
            }
        } else if let hint, hint.isVisible {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Theme.current.reducesMotion ? 0 : 0.4
                hint.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { hint.orderOut(nil) } })
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
        guard model.onboarding == nil else { return } // the flow ends with Done or Esc, not a stray click
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
