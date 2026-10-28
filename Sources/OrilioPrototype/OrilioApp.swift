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
    @AppStorage(StartupSettings.Keys.menuBarIcon) private var menuBarIcon = true

    var body: some Scene {
        // Hidden from Settings › Startup; opening Orilio again (Finder, Spotlight) then opens Settings.
        // SwiftUI writes `isInserted` back on every scene update; writing an unchanged value to the
        // defaults would post a change, rebuild the scene and loop, so only real changes are stored.
        MenuBarExtra("Orilio", systemImage: "rectangle.topthird.inset.filled",
                     isInserted: Binding(get: { menuBarIcon }, set: { if $0 != menuBarIcon { menuBarIcon = $0 } })) {
            MenuContent()
        }
    }
}

private struct MenuContent: View {
    var body: some View {
        // The quick way to the camera mirror; gone with the module when it is hidden.
        // Read from the preferences store, which exists before the menu is built (the island doesn't yet).
        if ModuleSettings(store: .shared).isVisible(.mirror) {
            Button("Mirror") { AppModules.island?.openMirror() }
            Divider()
        }
        Button("Settings…") { SettingsWindow.show() }
            .keyboardShortcut(",")
        #if DEBUG
        DebugMenu()
        #endif
        Divider()
        Button("Quit Orilio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var positioner: IslandPositioner?
    private var bridge: BridgeServer?
    private var shelf: ShelfModel?
    private var clipboard: ClipboardModule?
    private var notes: NotesModule?

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
        GlobalHotKey.register { [weak positioner] in positioner?.toggle() }
        startUp(island: island, positioner: positioner)
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

#if DEBUG
/// Stand-ins for checking the collapsed island's priority rules by hand. Debug builds only.
private struct DebugMenu: View {
    /// Looked up when the menu opens: the menu is built before the app has finished launching.
    private var island: IslandModel { AppModules.island! }

    var body: some View {
        Menu("Debug") {
            Button("Meeting in 4 min") { island.live.mockMeeting = Self.meeting(startingIn: 4 * 60) }
            Button("Meeting now") { island.live.mockMeeting = Self.meeting(startingIn: 0) }
            Button("End meeting") { island.live.mockMeeting = nil }
            Divider()
            Button(island.focus.isActive ? "Stop focus" : "Start focus") {
                island.focus.isActive ? island.focus.reset() : island.focus.begin()
            }
            Button("Fire \u{201C}Copied\u{201D}") {
                island.live.flash(Transient(title: "Copied", detail: "kubectl rollout restart deploy/api", monospaced: true, module: .clipboard))
            }
            Button("Fire \u{201C}Screenshot saved\u{201D}") {
                island.live.flash(Transient(symbol: "photo", title: "Screenshot saved to Shelf", module: .shelf))
            }
            Button("Play or pause demo music") { Task { await Self.toggleDemo(island) } }
            Divider()
            Menu("Hide or show a module") {
                ForEach(IslandTab.allCases) { tab in
                    Button("\(island.modules.isVisible(tab) ? "Hide" : "Show") \(tab.rawValue)") {
                        island.modules.setVisible(tab, !island.modules.isVisible(tab))
                    }
                }
            }
        }
    }

    static func meeting(startingIn seconds: TimeInterval) -> CalendarEvent {
        let start = Date().addingTimeInterval(seconds)
        return CalendarEvent(id: "debug.\(UUID().uuidString)", eventIdentifier: nil, title: "Design review", start: start,
                             end: start.addingTimeInterval(30 * 60), isAllDay: false, calendarID: "debug", calendarTitle: "Debug",
                             sourceTitle: "Debug", color: CalendarColor(red: 0.43, green: 0.66, blue: 1), attendeeNames: [],
                             meeting: MeetingLinkResolver.validate(URL(string: "https://meet.google.com/abc-defg-hij")!))
    }

    /// The Demo source plays no audio and talks to no app (it turns on "Show the Demo media source").
    @MainActor static func toggleDemo(_ island: IslandModel) async {
        UserDefaults.standard.set(true, forKey: SettingsKeys.showDemoSource)
        await island.demo.setEnabled(true)
        // The source shows up asynchronously; a command sent before that would be dropped.
        for _ in 0..<40 where !island.media.sessions.contains(where: { $0.sourceID == DemoMediaProvider.providerID }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        island.media.select(DemoMediaProvider.providerID)
        try? await island.media.send(.togglePlayPause, to: DemoMediaProvider.providerID)
    }
}
#endif

/// Orilio's own Settings window, so it can be opened from anywhere (launch, reopen, the menu).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            // The design's 1040 × 760 window: dark, no title, the traffic lights over the sidebar.
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [] // the window is the design's size; SwiftUI mustn't add the title bar to it
            let window = NSWindow(contentViewController: host)
            window.title = "Orilio Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1F / 255, alpha: 1)
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
