// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Chrome starts this same executable as Orilio's native messaging host.
        NativeMessagingHost.runIfLaunchedByChrome()
        OrilioApp.main()
    }
}

struct OrilioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar extra is an `NSStatusItem` (see `StatusMenu`); Settings is Orilio's own window.
        // An App needs a scene: this one never shows anything. (A `Settings` scene here would open an
        // empty window of its own on reopen and on ⌘,.)
        MenuBarExtra("Orilio", isInserted: .constant(false)) { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var positioner: IslandPositioner?
    private var bridge: BridgeServer?
    private var shelf: ShelfModel?
    private var clipboard: ClipboardModule?
    private var notes: NotesModule?
    private var statusMenu: StatusMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app switcher entry. Works without an Info.plist (LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        // One Orilio at a time: a second launch hands over to the running one ("reopen", which opens
        // Settings when the menu bar icon is hidden) and quits.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current && $0.activationPolicy != .prohibited } // Chrome's native host is no app
        if let running = others.first, let url = running.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            exit(0)
        }
    }

    /// Opening Orilio while it runs (Finder, Spotlight, a second launch).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !StartupSettings.showsMenuBarIcon { SettingsWindow.show() }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var providers: [any MediaProvider] = [ScriptablePlayerProvider(.spotify), ScriptablePlayerProvider(.music)]
        if let (browser, server) = BrowserMediaProvider.live() {
            providers.append(browser)
            bridge = server
        }
        let shelf = ShelfModel(store: ShelfStore())
        self.shelf = shelf
        Task { await shelf.restore() }
        let calendar = CalendarModule()
        AppModules.calendar = calendar
        calendar.start() // reads state only if the user turned Calendar on before; never prompts here
        let clipboard = ClipboardModule()
        self.clipboard = clipboard
        AppModules.clipboard = clipboard
        Task { await clipboard.start() } // monitors only if the user turned history on before
        let notes = NotesModule()
        self.notes = notes
        Task { await notes.load() }
        let focus = FocusModule()
        focus.start() // a session from before the restart resumes or completes; never prompts
        let modules = ModuleSettings(store: .shared) // one preferences store for modules and the theme
        AppModules.modules = modules
        let library = ScreenshotLibrary()
        Task { await library.load() } // metadata only; thumbnails load as cells appear
        library.startWatchingIfEnabled()
        AppModules.library = library
        let island = IslandModel(providers: providers, shelf: shelf, library: library,
                                 calendar: calendar, clipboard: clipboard, notes: notes, focus: focus, modules: modules,
                                 mirror: CameraMirrorModel())
        AppModules.island = island
        // One island per display that should have one; extra ones share every module and the music.
        let positioner = IslandPositioner(primary: island) {
            IslandModel(shelf: shelf, library: library, calendar: calendar, clipboard: clipboard, notes: notes,
                        focus: focus, modules: modules, live: island.live, sharing: island)
        }
        self.positioner = positioner
        statusMenu = StatusMenu(toggleIsland: { [weak positioner] in positioner?.toggle() },
                                open: { [weak positioner] in positioner?.open($0) })
        startUpdates(island: island)
        GlobalHotKeys.shared.perform = { [weak positioner] action in
            guard let positioner else { return }
            switch action {
            case .toggleIsland: positioner.toggle()
            case .openClipboard: positioner.open(.clipboard)
            case .toggleFocus: focus.toggle()
            case .newNote:
                notes.newNote()
                positioner.open(.notes)
            case .joinMeeting:
                let day = calendar.dayNow()
                if let event = island.meetingSoon ?? day.timed.first(where: { $0.meeting != nil && $0.end > day.now }) { island.join(event) }
            case .openMirror: positioner.open(.mirror)
            }
        }
        registerShortcuts()
        // Settings › Shortcuts and hiding a module both end up in the defaults.
        shortcutObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.registerShortcuts() }
        }
        if OnboardingModel.shouldShow() {
            // The first launch happens in the island; once the displays are placed.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                island.startOnboarding()
            }
        } else {
            startUp(island: island, positioner: positioner)
        }
    }

    private var shortcutObserver: NSObjectProtocol?

    private static func registerShortcuts() {
        guard let modules = AppModules.modules else { return }
        GlobalHotKeys.shared.register(PreferencesStore.shared.value.shortcutMap, hidden: modules.hidden)
    }

    private func registerShortcuts() { Self.registerShortcuts() }

    /// Sparkle, and what the island says about it. What's New waits for the first click on the island.
    private func startUpdates(island: IslandModel) {
        if WhatsNewGate.pending(current: AboutPane.version, defaults: .standard) { IslandModel.pendingWhatsNew = WhatsNew.bundled() }
        let updates = UpdateModel.shared
        updates.onReminder = { [weak island] update in
            guard let island, UpdateReminderPolicy.shouldRemind(version: update.version, alreadyReminded: updates.remindedVersion,
                                                                meetingShowing: island.meetingSoon != nil,
                                                                focusActive: island.focus.showsInEar,
                                                                transientShowing: island.live.transient != nil) else { return }
            updates.markReminded(update.version)
            island.live.flash(Transient(symbol: "arrow.down.circle.fill", title: "Update ready", module: island.modules.visible[0],
                                        pill: "Restart", action: .restartToUpdate, duration: .seconds(8)))
        }
        updates.onFailure = { [weak self, weak island] in
            guard let island else { return }
            self?.flashWhenQuiet(Transient(symbol: "exclamationmark.triangle.fill", title: "Update couldn’t install",
                                           module: island.modules.visible[0], pill: "Details", action: .showUpdates,
                                           warning: true, duration: .seconds(8)), on: island)
        }
        updates.start()
    }

    /// Shows the note once nothing else is live (a focus session or a meeting ends first).
    private func flashWhenQuiet(_ note: Transient, on island: IslandModel) {
        let quiet = UpdateReminderPolicy.isQuiet(meetingShowing: island.meetingSoon != nil, focusActive: island.focus.showsInEar,
                                                 transientShowing: island.live.transient != nil)
        guard !quiet else { return island.live.flash(note) }
        withObservationTracking { _ = (island.earLayout, island.focus.finished) } onChange: { [weak self, weak island] in
            Task { @MainActor in
                guard let self, let island else { return }
                self.flashWhenQuiet(note, on: island)
            }
        }
    }

    /// Settings › Startup › "When Orilio starts".
    private func startUp(island: IslandModel, positioner: IslandPositioner) {
        switch StartupSettings.launch {
        case .quiet:
            break
        case .settings:
            SettingsWindow.show()
        case .hello:
            // A moment later, once the displays and fullscreen state are known. Never over a
            // fullscreen app or a meeting (the only thing above a confirmation).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !positioner.pointerDisplayIsFullscreen, island.meetingSoon == nil else { return }
                island.live.flash(Transient(symbol: "sparkles", title: "Orilio is ready", module: island.modules.visible[0]))
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Write any shelf, clipboard or notes change still waiting for its coalesced save, then quit.
        guard let shelf else { return .terminateNow }
        Task {
            await shelf.saveNow()
            await clipboard?.saveNow()
            await notes?.saveNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }
}


/// The menu bar icon, with a mint dot while an update waits. Drawn with the menu bar's own text
/// color, so it reads in light and dark menu bars.
enum MenuBarIcon {
    static func image(dot: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Orilio")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
        guard dot else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = NSRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: glyph)
            NSColor.labelColor.set()
            glyph.fill(using: .sourceAtop)
            NSColor(srgbRed: 0x2B / 255, green: 1, blue: 0xB8 / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        image.accessibilityDescription = "Orilio, update ready"
        return image
    }
}

/// Orilio's own Settings window, so it can be opened from anywhere (launch, reopen, the menu).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    /// Opens Settings, on `pane` when given (the island's "Details" opens Updates).
    static func show(pane: SettingsView.Pane? = nil) {
        if let pane { SettingsNavigation.shared.pane = pane }
        if window == nil {
            // The design's 1040 × 760 window: no title, the traffic lights over the sidebar; it follows
            // the system appearance.
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [] // the window is the design's size; SwiftUI mustn't add the title bar to it
            let window = NSWindow(contentViewController: host)
            window.title = "Orilio Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? SettingsDesign.ns(0x1C1C1F) : .white }
            // With a full-size content view the frame is the content: exactly the design's 1040 × 760.
            window.setFrame(NSRect(x: 0, y: 0, width: 1040, height: 760), display: false)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // An accessory app is never frontmost on its own. macOS may decline the activation (it does
        // when the request doesn't come from a click in Orilio), so also bring the window forward
        // regardless; a click in it then activates Orilio.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
