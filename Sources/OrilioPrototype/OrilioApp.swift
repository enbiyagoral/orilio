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
        controller = IslandWindowController(model: IslandModel(providers: providers))
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }
}
