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
        Divider()
        Button("Quit Orilio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandWindowController?
    private var bridge: BridgeServer?
    private var shelf: ShelfModel?
    private var clipboard: ClipboardModule?

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
        let library = ScreenshotLibrary()
        Task { await library.load() } // metadata only; thumbnails load as cells appear
        controller = IslandWindowController(model: IslandModel(providers: providers, shelf: shelf, library: library,
                                                               calendar: calendar, clipboard: clipboard))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Write any shelf or clipboard change still waiting for its coalesced save, then quit.
        guard let shelf else { return .terminateNow }
        Task {
            await shelf.saveNow()
            await clipboard?.saveNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }
}
