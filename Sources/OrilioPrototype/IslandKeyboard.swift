// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI

// The island's keys (the M5 Keyboard design). They only arrive while the island panel is key:
// opened by a click or a shortcut, never by hover. No global key monitoring.

/// One key press, reduced to what the routing needs. Pure, so the table is tested.
struct KeyPress: Equatable {
    var keyCode: UInt16
    var characters = ""
    var command = false
    var shift = false
    var control = false
    var option = false

    init(keyCode: UInt16, characters: String = "", command: Bool = false, shift: Bool = false, control: Bool = false, option: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.command = command
        self.shift = shift
        self.control = control
        self.option = option
    }

    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                  command: flags.contains(.command), shift: flags.contains(.shift),
                  control: flags.contains(.control), option: flags.contains(.option))
    }
}

enum IslandKeyAction: Equatable {
    /// ⌘1–6: the nth visible module, in the user's order.
    case module(Int)
    /// ⌃⇥ / ⌃⇧⇥, ⇥.
    case adjacentModule(Int)
    /// ↑↓ in a list (and ←→ between Shelf tiles).
    case move(Int)
    /// ⏎: Join, Start, Play, Copy, Open, Done.
    case primary
    /// Space: Quick Look.
    case preview
    /// ⌘P: pin the clipboard item.
    case pinItem
    /// ⌘⌫.
    case deleteItem
    /// ⌘F.
    case search
    /// A letter typed in the clipboard list goes into its search; in Notes, into the note.
    case type(String)
    case settings
    /// ⌘⇧P.
    case togglePin
    case close
    /// ⌘W.
    case closeAndUnpin
    /// Esc in a one-line field: leave the field (a rename is cancelled); the next Esc closes.
    case endEditing

    var actsOnTheShelfList: Bool {
        switch self {
        case .move, .primary, .preview, .deleteItem: true
        default: false
        }
    }
}

enum IslandKeyRouter {
    /// What has the keyboard inside the island: nothing (the panel), the clipboard's search field,
    /// a note being written, or another one-line field (the Notes search, a task being added or renamed).
    enum Editing { case none, search, text, field }

    static let listModules: Set<IslandTab> = [.clipboard, .shelf, .notes]

    static func route(_ key: KeyPress, tab: IslandTab, editing: Editing = .none) -> IslandKeyAction? {
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6]
        let list = listModules.contains(tab)
        // ⌘ combinations work everywhere, also while typing (except ⌘⌫, which deletes text there).
        if key.command, !key.control, !key.option {
            if let n = digits[key.keyCode], !key.shift { return .module(n - 1) }
            switch (key.keyCode, key.shift) {
            case (35, true): return .togglePin                          // ⌘⇧P
            case (35, false): return tab == .clipboard ? .pinItem : nil // ⌘P
            case (13, false): return .closeAndUnpin                     // ⌘W
            case (43, false): return .settings                          // ⌘,
            case (3, false): return tab == .clipboard ? .search : nil   // ⌘F
            case (51, false): return list && editing == .none ? .deleteItem : nil // ⌘⌫ (in a field it clears text)
            default: return nil
            }
        }
        if key.control, key.keyCode == 48 { return .adjacentModule(key.shift ? -1 : 1) } // ⌃⇥, ⌃⇧⇥
        // Esc closes, also while writing a note; a one-line field is left first, as anywhere on the Mac.
        if key.keyCode == 53 { return editing == .search || editing == .field ? .endEditing : .close }
        switch editing {
        case .text, .field: return nil // the editor keeps every other key
        case .search:
            switch key.keyCode {
            case 126: return .move(-1)
            case 125: return .move(1)
            case 36, 76: return .primary
            default: return nil
            }
        case .none:
            break
        }
        guard !key.command, !key.control else { return nil }
        switch key.keyCode {
        case 48: return .adjacentModule(key.shift ? -1 : 1) // ⇥ Next
        case 36, 76: return .primary
        case 49: return tab == .shelf ? .preview : nil
        case 126: return list ? .move(tab == .shelf ? -5 : -1) : nil // a Shelf row is five tiles
        case 125: return list ? .move(tab == .shelf ? 5 : 1) : nil
        case 123: return tab == .shelf ? .move(-1) : nil
        case 124: return tab == .shelf ? .move(1) : nil
        default:
            // A letter goes into the clipboard's search, or starts typing in the note.
            if tab == .clipboard || tab == .notes, let c = key.characters.first, c.isLetter || c.isNumber { return .type(String(c)) }
            return nil
        }
    }
}

/// The one list cursor Clipboard, Shelf and Tasks share: the next item from the current one,
/// held at the ends; the first item when nothing is selected yet.
enum ListCursor {
    static func moved<ID: Equatable>(_ current: ID?, in ids: [ID], by step: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return step < 0 ? ids.last : ids.first }
        return ids[min(ids.count - 1, max(0, index + step))]
    }
}

/// Hold ⌘ for 400 ms and the module tabs show their numbers. Pure timing.
struct CommandHold {
    static let delay: TimeInterval = 0.4
    private(set) var downAt: TimeInterval?

    /// ⌘ alone went down or up; any other key or modifier cancels the hold.
    mutating func changed(commandOnly: Bool, at now: TimeInterval) {
        if commandOnly { if downAt == nil { downAt = now } } else { downAt = nil }
    }

    mutating func cancel() { downAt = nil }

    func showsBadges(at now: TimeInterval) -> Bool { downAt.map { now - $0 >= Self.delay } ?? false }
}

/// The hint bar's keys for each module (only when the island was opened from the keyboard).
enum KeyHints {
    static func hints(for tab: IslandTab) -> [(key: String, label: String)] {
        switch tab {
        case .calendar: [("⏎", "Join"), ("⇥", "Next"), ("⌘", "Modules"), ("esc", "Close")]
        case .focus: [("⏎", "Start or pause"), ("⇥", "Next"), ("⌘", "Modules"), ("esc", "Close")]
        case .music: [("⏎", "Play or pause"), ("⇥", "Next"), ("⌘", "Modules"), ("esc", "Close")]
        case .clipboard: [("↑↓", "Move"), ("⏎", "Copy"), ("⌘P", "Pin"), ("⌘⌫", "Delete"), ("esc", "Close")]
        case .shelf: [("↑↓", "Move"), ("⏎", "Open"), ("␣", "Preview"), ("⌘⌫", "Remove"), ("esc", "Close")]
        case .notes: [("↑↓", "Move"), ("⏎", "Done"), ("⌘⌫", "Delete"), ("esc", "Close")]
        case .mirror: [("⇥", "Next"), ("⌘", "Modules"), ("esc", "Close")]
        case .extensions: [("⇥", "Next"), ("⌘", "Modules"), ("esc", "Close")]
        }
    }
}

/// The bar along the bottom of a keyboard-opened island: 44 pt, a hairline on top, keycaps of 12%
/// white with their meaning.
struct KeyHintBar: View {
    let tab: IslandTab

    var body: some View {
        HStack(spacing: 18) {
            ForEach(KeyHints.hints(for: tab), id: \.label) { hint in
                HStack(spacing: 6) {
                    Text(L(hint.key))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 20)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(L(hint.label))
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(.black)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Keyboard: ") + KeyHints.hints(for: tab).map { "\($0.key) \(L($0.label))" }.joined(separator: ", "))
    }
}

extension EnvironmentValues {
    /// The island was opened from the keyboard: the main action wears the focus ring.
    @Entry var keyboardFocusVisible = false
}

private struct KeyboardFocusRing: ViewModifier {
    let primary: Bool
    let radius: CGFloat
    @Environment(\.keyboardFocusVisible) private var visible

    func body(content: Content) -> some View {
        content.overlay {
            if primary, visible {
                // The design's ring: 2 pt of black, then 2 pt of white.
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// A white focus ring on the module's main action while the island was opened from the keyboard.
    func keyboardFocusRing(_ primary: Bool, radius: CGFloat = 10) -> some View {
        modifier(KeyboardFocusRing(primary: primary, radius: radius))
    }
}

/// Two-finger horizontal swipes on the trackpad: one action per gesture, decided from the first few
/// points of movement, so a vertical scroll (lists, the screenshot grid) never turns into a swipe.
/// Pure; fed with the finger's movement (the scroll deltas with natural scrolling undone).
struct SwipeTracker {
    enum Direction: Equatable { case left, right }
    enum Phase { case began, changed, ended, other }

    /// Movement before the axis is decided, and how far a horizontal one has to go.
    static let decideAfter: CGFloat = 8
    static let threshold: CGFloat = 60

    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var dx: CGFloat = 0, dy: CGFloat = 0
    private var fired = false

    mutating func event(_ phase: Phase, dx fingerDX: CGFloat, dy fingerDY: CGFloat) -> Direction? {
        switch phase {
        case .began:
            self = SwipeTracker()
            return add(fingerDX, fingerDY)
        case .changed:
            return add(fingerDX, fingerDY)
        case .ended, .other:
            self = SwipeTracker()
            return nil
        }
    }

    private mutating func add(_ x: CGFloat, _ y: CGFloat) -> Direction? {
        dx += x
        dy += y
        if axis == .undecided, abs(dx) + abs(dy) >= Self.decideAfter {
            axis = abs(dx) > 1.5 * abs(dy) ? .horizontal : .vertical
        }
        guard axis == .horizontal, !fired, abs(dx) >= Self.threshold else { return nil }
        fired = true
        return dx < 0 ? .left : .right
    }
}
