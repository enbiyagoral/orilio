import AppKit
import Carbon.HIToolbox
import Observation

/// One key with modifiers, as Carbon registers it. `key` is how it is drawn ("Space", "V").
struct HotKeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    /// A shortcut the user cleared (Delete while recording).
    static let none = HotKeyCombo(keyCode: 0, modifiers: 0, key: "")
    var isNone: Bool { modifiers == 0 }

    static func controlOption(_ keyCode: Int, _ key: String) -> HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(controlKey | optionKey), key: key)
    }

    /// ⌃ ⌥ ⇧ ⌘ then the key, in the order macOS menus draw them.
    var keycaps: [String] {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1) + [key]
    }

    var spoken: String {
        let names = [(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")]
        return (names.filter { modifiers & UInt32($0.0) != 0 }.map(\.1) + [key]).joined(separator: " ")
    }

    /// A key press while recording. Nil unless it has ⌃, ⌥ or ⌘: a global shortcut needs one.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        guard carbon & (controlKey | optionKey | cmdKey) != 0 else { return nil }
        let code = Int(event.keyCode)
        let name = Self.specialKeys[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(carbon), key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// The six global shortcuts of Settings › Shortcuts.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case toggleIsland, openClipboard, toggleFocus, newNote, joinMeeting, openMirror
    var id: Self { self }

    var title: String {
        switch self {
        case .toggleIsland: "Toggle the island"
        case .openClipboard: "Open clipboard"
        case .toggleFocus: "Start or pause focus"
        case .newNote: "New quick note"
        case .joinMeeting: "Join next meeting"
        case .openMirror: "Open mirror"
        }
    }

    var symbol: String {
        switch self {
        case .toggleIsland: "rectangle.topthird.inset.filled"
        case .openClipboard: "doc.on.clipboard"
        case .toggleFocus: "timer"
        case .newNote: "pencil"
        case .joinMeeting: "video"
        case .openMirror: "camera"
        }
    }

    var defaultCombo: HotKeyCombo {
        switch self {
        case .toggleIsland: .controlOption(kVK_Space, "Space")
        case .openClipboard: .controlOption(kVK_ANSI_V, "V")
        case .toggleFocus: .controlOption(kVK_ANSI_F, "F")
        case .newNote: .controlOption(kVK_ANSI_N, "N")
        case .joinMeeting: .controlOption(kVK_ANSI_J, "J")
        case .openMirror: .controlOption(kVK_ANSI_M, "M")
        }
    }

    /// The module the shortcut belongs to: hidden, it is off.
    var module: IslandTab? {
        switch self {
        case .toggleIsland: nil
        case .openClipboard: .clipboard
        case .toggleFocus: .focus
        case .newNote: .notes
        case .joinMeeting: .calendar
        case .openMirror: .mirror
        }
    }
}

/// Which shortcuts to register. Pure: a combination two actions share goes to the first (in the
/// Settings order) and the other is a conflict; cleared shortcuts and hidden modules register nothing.
enum HotKeyPlan {
    static func resolve(_ combos: [ShortcutAction: HotKeyCombo], hidden: Set<IslandTab>)
        -> (register: [(ShortcutAction, HotKeyCombo)], conflicts: Set<ShortcutAction>) {
        var taken = Set<HotKeyCombo>(), register: [(ShortcutAction, HotKeyCombo)] = [], conflicts = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            guard let combo = combos[action], !combo.isNone, !(action.module.map(hidden.contains) ?? false) else { continue }
            let same = HotKeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers, key: "")
            if taken.insert(same).inserted { register.append((action, combo)) } else { conflicts.insert(action) }
        }
        return (register, conflicts)
    }
}

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`: public, needs no Accessibility
/// permission, and works over fullscreen apps.
@MainActor @Observable
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    /// Shortcuts another app holds, or that another Orilio shortcut already uses.
    private(set) var conflicts: Set<ShortcutAction> = []
    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var registered: [UInt32: ShortcutAction] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored var perform: (ShortcutAction) -> Void = { _ in }

    @ObservationIgnored private var wanted: (combos: [ShortcutAction: HotKeyCombo], hidden: Set<IslandTab>)?
    /// True while Settings records a shortcut: its current combination must reach the recorder.
    @ObservationIgnored var paused = false {
        didSet { if paused != oldValue { apply() } }
    }

    /// Registers these shortcuts in place of the current ones (nothing happens when unchanged).
    func register(_ combos: [ShortcutAction: HotKeyCombo], hidden: Set<IslandTab>) {
        if let wanted, wanted.combos == combos, wanted.hidden == hidden { return }
        wanted = (combos, hidden)
        apply()
    }

    private func apply() {
        installHandler()
        unregisterAll()
        guard let wanted, !paused else { return }
        let plan = HotKeyPlan.resolve(wanted.combos, hidden: wanted.hidden)
        var conflicts = plan.conflicts
        for (index, (action, combo)) in plan.register.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: OSType(0x4F52_494C), id: id), // "ORIL"
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                registered[id] = action
            } else {
                conflicts.insert(action)
            }
        }
        if conflicts != self.conflicts { self.conflicts = conflicts }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        registered = [:]
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                let keys = GlobalHotKeys.shared
                if let action = keys.registered[id.id] { keys.perform(action) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
