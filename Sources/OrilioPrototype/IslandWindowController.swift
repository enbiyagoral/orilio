import AppKit
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

    static let pillWidth: CGFloat = 220     // fits a mini cover + a short title in the menu bar band
    static let fullWidth: CGFloat = 540
    static let fullHeight: CGFloat = 170    // 6 + 26pt header + 14 + 96pt cover + 18 + slack for the progress row
    static let previewWidth: CGFloat = 360
    static let previewHeight: CGFloat = 64  // one row: 40pt cover + 12pt padding above and below

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

    /// Hover: a single glanceable row.
    var preview: CGSize {
        CGSize(width: max(Self.previewWidth, collapsed.width), height: topInset + Self.previewHeight)
    }

    /// Click: the full controller.
    var full: CGSize {
        CGSize(width: Self.fullWidth, height: topInset + Self.fullHeight)
    }

    func size(for state: IslandState) -> CGSize {
        switch state {
        case .collapsed: collapsed
        case .expanded: preview
        case .pinned: full
        }
    }

    /// Collapsed: exactly the island. Open: the island plus ears and shadow room.
    func windowFrame(for state: IslandState) -> CGRect {
        var size = size(for: state)
        if state.isOpen {
            size.width += 2 * (Self.earRadius + Self.shadowMargin)
            size.height += Self.shadowMargin
        }
        return CGRect(x: (centerX - size.width / 2).rounded(), y: screenTop - size.height,
                      width: size.width, height: size.height)
    }

    /// `auxLeftWidth`/`auxRightWidth` are the menu bar areas either side of the notch
    /// (`NSScreen.auxiliaryTopLeftArea`/`…RightArea`); the notch is what lies between them.
    static func make(screenFrame: CGRect, safeAreaTop: CGFloat,
                     auxLeftWidth: CGFloat?, auxRightWidth: CGFloat?,
                     menuBarHeight: CGFloat) -> IslandGeometry {
        if safeAreaTop > 0, let left = auxLeftWidth, let right = auxRightWidth {
            let notch = screenFrame.width - left - right
            return IslandGeometry(topInset: safeAreaTop, notchWidth: notch,
                                  centerX: screenFrame.minX + left + notch / 2, screenTop: screenFrame.maxY)
        }
        return IslandGeometry(topInset: menuBarHeight, notchWidth: 0,
                              centerX: screenFrame.midX, screenTop: screenFrame.maxY)
    }

    static func make(for screen: NSScreen) -> IslandGeometry {
        let band = screen.frame.maxY - screen.visibleFrame.maxY
        return make(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                    auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
                    auxRightWidth: screen.auxiliaryTopRightArea?.width,
                    // band is 0 when the menu bar auto-hides
                    menuBarHeight: band > 0 ? band : NSStatusBar.system.thickness)
    }
}

/// Non-activating, so hovering or clicking controls never pulls focus from the user's app.
/// Only pinning activates it (see `IslandWindowController.apply`).
final class IslandPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class IslandHostingView: NSHostingView<IslandView> {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    required init(rootView: IslandView) {
        super.init(rootView: rootView)
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
}

@MainActor
final class IslandWindowController {
    private let model: IslandModel
    private let panel: IslandPanel
    private var shrinkTask: Task<Void, Never>?
    /// Watches for clicks outside the island while the full controller is open. Mouse monitors
    /// need no permission; it exists only while pinned.
    private var outsideClickMonitor: Any?

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Just above the menu bar (.mainMenu) so the island can sit inside its band.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = [] // the controller owns the frame; don't let SwiftUI resize the panel
        host.onHover = { [weak model] in model?.hover($0) }
        panel.contentView = host
        panel.onEscape = { [weak model] in model?.dismiss() }
        model.onWillChangeState = { [weak self] in self?.apply($0) }

        let center = NotificationCenter.default
        let onChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: onChange)
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: onChange)
        // Another app came forward (including the source the user just jumped to): put the controller away.
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { if model?.state == .pinned { model?.dismiss() } }
        }
        // Wake and unlock: sessions missed their heartbeats while the Mac was away.
        let recover: @Sendable (Notification) -> Void = { [weak model] _ in
            MainActor.assumeIsolated { model?.media.systemDidWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recover)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main, using: recover)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onChange)

        reposition()
        panel.orderFrontRegardless()
    }

    private var targetScreen: NSScreen? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SettingsKeys.preferNotchedDisplay),
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first // the primary (menu bar) screen
    }

    func reposition() {
        let defaults = UserDefaults.standard
        model.hoverOpens = defaults.object(forKey: SettingsKeys.openOnHover) as? Bool ?? true
        let showDemo = defaults.bool(forKey: SettingsKeys.showDemoSource)
        Task { [demo = model.demo] in await demo.setEnabled(showDemo) }
        guard let screen = targetScreen else { return }
        let geometry = IslandGeometry.make(for: screen)
        if geometry != model.geometry { model.geometry = geometry }
        panel.setFrame(geometry.windowFrame(for: model.state), display: true)
    }

    private func apply(_ state: IslandState) {
        shrinkTask?.cancel()
        watchOutsideClicks(state == .pinned)

        if state == .pinned {
            // Pinning is an explicit click, so taking the keyboard (for Esc) is intended.
            // The app has no other windows, so activating it raises nothing else.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        } else if !state.isOpen, NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            // Give the keyboard back to the app the user was in (skipped while Settings is open).
            NSApp.deactivate()
        }

        let target = model.geometry.windowFrame(for: state)
        if target.width >= panel.frame.width, target.height >= panel.frame.height {
            panel.setFrame(target, display: true)
            panel.contentView?.layoutSubtreeIfNeeded() // settle the current island in the bigger window
        } else {
            // Keep the window large until the SwiftUI shrink animation has finished, then shrink it
            // so the empty area stops catching clicks.
            let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : IslandModel.closeDuration
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.model.state == state else { return }
                self.panel.setFrame(target, display: true)
            }
        }
    }

    private func watchOutsideClicks(_ on: Bool) {
        if on, outsideClickMonitor == nil {
            // Global monitors see only clicks in other apps, so anything they report is outside the island.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.dismiss() }
            }
        } else if !on, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
