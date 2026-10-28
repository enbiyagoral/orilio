import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// What Orilio does when it starts, and how it stays reachable. `UserDefaults`, `startup.*`.
enum StartupSettings {
    enum Launch: String, CaseIterable, Identifiable {
        case quiet, hello, settings
        var id: Self { self }
        var title: String {
            switch self {
            case .quiet: "Stay quietly in the notch"
            case .hello: "Show a short hello"
            case .settings: "Open Settings"
            }
        }
        var detail: String {
            switch self {
            case .quiet: "No window, no sound. Best for login."
            case .hello: "The island says it's ready for two seconds."
            case .settings: "Useful while you are still setting things up."
            }
        }
    }

    enum Keys {
        static let launch = "startup.launch"
        static let menuBarIcon = "startup.menuBarIcon"
    }

    static var launch: Launch {
        UserDefaults.standard.string(forKey: Keys.launch).flatMap(Launch.init(rawValue:)) ?? .quiet
    }

    static var showsMenuBarIcon: Bool { UserDefaults.standard.object(forKey: Keys.menuBarIcon) as? Bool ?? true }
}

/// Open at login through `SMAppService.mainApp`: macOS keeps the list (System Settings › General ›
/// Login Items), so the status is always read back from it, never remembered.
enum LoginItem {
    enum Status: Equatable {
        case enabled, requiresApproval, off
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .off // .notRegistered, .notFound
        }
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`: public, needs no Accessibility
/// permission, and works over fullscreen apps.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥Space. Recording a custom shortcut comes later.
    static let display = ["⌃", "⌥", "Space"]
    private static let keyCode = UInt32(kVK_Space)
    private static let modifiers = UInt32(controlKey | optionKey)

    /// The one registered shortcut; the C callback can't carry Swift context.
    private static var shared: GlobalHotKey?
    private(set) static var isRegistered = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    private init(action: @escaping () -> Void) { self.action = action }

    /// Registers ⌃⌥Space. False when another app already holds it.
    @discardableResult
    static func register(action: @escaping () -> Void) -> Bool {
        let key = GlobalHotKey(action: action)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.shared?.action() }
            return noErr
        }, 1, &spec, nil, &key.handler)
        let id = EventHotKeyID(signature: OSType(0x4F52_494C), id: 1) // "ORIL"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &key.hotKey)
        guard status == noErr else {
            if let handler = key.handler { RemoveEventHandler(handler) }
            isRegistered = false
            return false
        }
        shared = key
        isRegistered = true
        return true
    }
}
