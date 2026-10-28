import AppKit
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
            case .hello: "The island opens for two seconds, then collapses."
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
