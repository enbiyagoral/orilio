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
        MenuBarExtra("Orilio", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent()
        }
        Settings {
            SettingsView()
        }
    }
}

private struct MenuContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            // Accessory apps are never frontmost on their own; without this the window opens behind.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        #if DEBUG
        DebugMenu()
        #endif
        Divider()
        Button("Quit Orilio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var positioner: IslandPositioner?
    private var bridge: BridgeServer?
    private var shelf: ShelfModel?
    private var clipboard: ClipboardModule?
    private var notes: NotesModule?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app switcher entry. Works without an Info.plist (LSUIElement).
        NSApp.setActivationPolicy(.accessory)
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
        let modules = ModuleSettings()
        AppModules.modules = modules
        let library = ScreenshotLibrary()
        Task { await library.load() } // metadata only; thumbnails load as cells appear
        library.startWatchingIfEnabled()
        AppModules.library = library
        let island = IslandModel(providers: providers, shelf: shelf, library: library,
                                 calendar: calendar, clipboard: clipboard, notes: notes, focus: focus, modules: modules)
        AppModules.island = island
        // One island per display that should have one; extra ones share every module and the music.
        positioner = IslandPositioner(primary: island) {
            IslandModel(shelf: shelf, library: library, calendar: calendar, clipboard: clipboard, notes: notes,
                        focus: focus, modules: modules, live: island.live, sharing: island)
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
