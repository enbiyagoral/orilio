// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation

/// What the collapsed island can show, highest priority first.
enum LiveActivityKind: Int, Comparable {
    case meeting, focus, transient, extensionEar, nowPlaying
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A short confirmation ("Copied", "Screenshot saved"): shown for 2 s, never queued.
struct Transient: Equatable {
    let id = UUID()
    var symbol = "checkmark"
    let title: String
    var detail: String?
    var monospaced = false
    /// The module a click opens.
    let module: IslandTab
    /// A pill on the right ("Restart", "Details") and what a click does instead of opening `module`.
    var pill: String? = nil
    var action: TransientAction? = nil
    /// Amber: something went wrong.
    var warning = false
    /// How long it stays (a confirmation 2 s; an update note longer).
    var duration: Duration = .seconds(2)
}

enum TransientAction: Equatable { case restartToUpdate, showUpdates }

/// What the focus ear shows: the ring and time, a break (blue, "break" on the right when music
/// leaves it free), or what just ended and waits for the user.
enum FocusEarKind: Equatable {
    case running, onBreak, done(String)

    @MainActor init?(_ focus: FocusModule) {
        switch focus.finished {
        case .session?: self = .done("Session done")
        case .breakOver?: self = .done("Break over")
        case nil: if focus.isOnBreak { self = .onBreak } else if focus.isActive { self = .running } else { return nil }
        }
    }
}

/// One thing claiming one or both ears of the collapsed island.
struct LiveActivity: Equatable, Identifiable {
    enum Payload: Equatable {
        case meeting(CalendarEvent)
        case focus(FocusEarKind)
        case transient(Transient)
        case nowPlaying(MediaSessionSnapshot)
        /// An extension's ears; with music playing it keeps only the leading one.
        case extensionEar(ExtensionEarContent, withMusic: Bool)
    }

    let payload: Payload

    var kind: LiveActivityKind {
        switch payload {
        case .meeting: .meeting
        case .focus: .focus
        case .transient: .transient
        case .nowPlaying: .nowPlaying
        case .extensionEar: .extensionEar
        }
    }

    var id: String {
        switch payload {
        case .meeting(let event): "meeting.\(event.id)"
        case .focus: "focus"
        case .transient(let transient): "transient.\(transient.id)"
        case .nowPlaying(let session): "music.\(session.sourceID)"
        case .extensionEar(let content, _): "extension.\(content.extensionID)"
        }
    }

    /// The module this activity belongs to: hidden modules never claim the notch, and a click opens it.
    var module: IslandTab {
        switch payload {
        case .meeting: .calendar
        case .focus: .focus
        case .transient(let transient): transient.module
        case .nowPlaying: .music
        case .extensionEar: .extensions
        }
    }
}

enum EarSide { case leading, trailing }

/// The collapsed island's two ears. One activity may take both (a meeting, a confirmation, music
/// alone); a focus session takes the leading ear and leaves the trailing one to music.
struct EarLayout: Equatable {
    var leading: LiveActivity?
    var trailing: LiveActivity?

    static let idle = EarLayout()
    var isIdle: Bool { leading == nil && trailing == nil }

    /// The highest-priority activity shown: where hovering opens the island.
    var primary: LiveActivity? { [leading, trailing].compactMap { $0 }.min { $0.kind < $1.kind } }

    func activity(at side: EarSide) -> LiveActivity? { side == .leading ? leading ?? trailing : trailing ?? leading }
}

/// The priority rules, in one place. Pure.
///
/// 1. A meeting within 10 minutes (and the first 5 after it starts) takes both ears.
/// 2. A confirmation takes both ears for 2 s, over anything except a meeting.
/// 3. A focus session takes the leading ear; music playing may keep the trailing one.
/// 4. An extension's ears (a prayer countdown); music playing keeps the trailing one.
/// 5. Music playing takes both ears.
/// 6. Otherwise idle: the island is the notch.
///
/// Hidden modules and indicators the user turned off never claim the notch.
enum LiveActivityResolver {
    static func layout(meeting: CalendarEvent?, focus: FocusEarKind?, transient: Transient?,
                       nowPlaying: MediaSessionSnapshot?, visible: Set<IslandTab>,
                       indicators: Set<CollapsedIndicator>, extensionEar: ExtensionEarContent? = nil) -> EarLayout {
        func allowed(_ module: IslandTab, _ indicator: CollapsedIndicator?) -> Bool {
            visible.contains(module) && indicator.map(indicators.contains) ?? true
        }
        if let meeting, allowed(.calendar, .meeting) {
            let activity = LiveActivity(payload: .meeting(meeting))
            return EarLayout(leading: activity, trailing: activity)
        }
        if let transient, allowed(transient.module, nil) {
            let activity = LiveActivity(payload: .transient(transient))
            return EarLayout(leading: activity, trailing: activity)
        }
        let music = nowPlaying.flatMap { allowed(.music, .music) ? LiveActivity(payload: .nowPlaying($0)) : nil }
        if let focus, allowed(.focus, .focus) {
            let activity = LiveActivity(payload: .focus(focus))
            return EarLayout(leading: activity, trailing: music ?? (focus == .onBreak ? activity : nil))
        }
        if let extensionEar, allowed(.extensions, nil) {
            let activity = LiveActivity(payload: .extensionEar(extensionEar, withMusic: music != nil))
            return EarLayout(leading: activity, trailing: music ?? activity)
        }
        return EarLayout(leading: music, trailing: music)
    }
}

// MARK: - Ear widths

extension EarLayout {
    static let maxEar: CGFloat = 150
    static let padding: CGFloat = 14   // from the island's edge to the content
    static let notchGap: CGFloat = 8   // between the content and the notch
    /// Without a notch, the floating pill keeps this much between the two ears.
    static let pillGap: CGFloat = 24

    /// The width each ear needs for its content, clamped. Both ears get the larger one so the
    /// island stays centered on the notch.
    func earWidth(now: Date) -> CGFloat {
        let widest = max(leading.map { Self.contentWidth($0, side: .leading, now: now) } ?? 0,
                         trailing.map { Self.contentWidth($0, side: .trailing, now: now) } ?? 0)
        return widest == 0 ? 0 : min(Self.maxEar, (Self.padding + widest + Self.notchGap).rounded(.up))
    }

    /// The collapsed island's width: the notch plus two ears, or the floating pill on other screens.
    func collapsedWidth(notch: CGFloat, pill: CGFloat, now: Date) -> CGFloat? {
        guard !isIdle else { return nil }
        let ear = earWidth(now: now)
        return notch > 0 ? notch + 2 * ear : max(pill, 2 * ear + Self.pillGap - 2 * Self.notchGap)
    }

    static func text(_ string: String, size: CGFloat = 12, weight: NSFont.Weight = .semibold, mono: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    static func contentWidth(_ activity: LiveActivity, side: EarSide, now: Date) -> CGFloat {
        switch (activity.payload, side) {
        case (.meeting(let event), .leading):
            return 7 + 7 + text(MeetingEar.title(event, now: now))
        case (.meeting(let event), .trailing):
            return MeetingEar.showsJoin(event, now: now) ? 4 + text("Join", size: 11.5, weight: .bold) + 20
                : text(CalendarDay.countdown(to: event.start, from: now))
        case (.focus(.done(let label)), .leading):
            return 14 + 6 + text(label)
        case (.focus, .leading):
            return 14 + 6 + text("88:88")
        case (.focus(.onBreak), .trailing):
            return text("break", size: 11.5, weight: .regular)
        case (.focus, .trailing):
            return 0
        case (.transient(let transient), .leading):
            return 14 + 7 + text(transient.title)
        case (.transient(let transient), .trailing):
            if let pill = transient.pill { return text(pill, size: 11.5) + 20 }
            return min(96, transient.detail.map { text($0, weight: .regular, mono: transient.monospaced) } ?? 0)
        case (.nowPlaying, .leading):
            return 20
        case (.nowPlaying, .trailing):
            return EqualizerView.Style.wave.size.width
        case (.extensionEar(let content, let withMusic), _):
            guard let part = ExtensionEarContent.part(content, side: side, withMusic: withMusic) else { return 0 }
            let icon: CGFloat = ExtensionIcons.symbol(part.icon) == nil ? 0 : 11 + 6
            // The countdown's text as it reads now ("2 h 55 min"); the ear is re-measured as it changes.
            let countdown = part.target.map { ExtensionCountdown.text(to: $0, from: now) } ?? ""
            return icon + text(part.style == "countdown" ? countdown : part.text ?? "")
        }
    }
}

/// What the meeting ears say, shared by the view and the width.
enum MeetingEar {
    static func started(_ event: CalendarEvent, now: Date) -> Bool { event.start <= now }
    static func title(_ event: CalendarEvent, now: Date) -> String { started(event, now: now) ? "\(event.title) · now" : event.title }
    /// At start time the trailing ear is a one-click Join (when the event has a meeting link).
    static func showsJoin(_ event: CalendarEvent, now: Date) -> Bool { started(event, now: now) && event.meeting != nil }
}

// MARK: - Coordinator

/// Holds the one transient confirmation. The layout itself
/// is derived from the modules' observable state (`IslandModel.earLayout`), so nothing polls.
@MainActor @Observable
final class LiveActivityCoordinator {
    private(set) var transient: Transient?

    @ObservationIgnored private let transientDuration: Duration
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init(transientDuration: Duration = .seconds(2)) {
        self.transientDuration = transientDuration
    }

    /// Shows a confirmation for 2 s. A new one replaces the old one; nothing queues.
    func flash(_ new: Transient) {
        expiry?.cancel()
        transient = new
        // The only timer here: a one-shot that ends this confirmation.
        expiry = Task { [weak self, duration = new.duration == .seconds(2) ? transientDuration : new.duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.transient?.id == new.id else { return }
            self.transient = nil
        }
    }

    func clearTransient() {
        expiry?.cancel()
        transient = nil
    }
}
