import Foundation

// Which card each module shows, from what it knows about access and data. Pure, so every state
// in the M5 States design has a test.

enum CalendarCardState: Equatable {
    /// First open: "Show your meetings up here?" (Continue asks macOS).
    case ask
    /// The user said Not now: "Calendar access is off" with Turn on.
    case declined
    /// macOS says no (also when access was revoked in System Settings).
    case denied
    case restricted
    case noCalendars
    /// Nothing more today; the next event in the coming week, if any.
    case clearRestOfDay(next: CalendarEvent?)
    /// The day's events; `offline` adds the "Join links work once you're back online" line.
    case events(offline: Bool)

    static func resolve(status: CalendarModule.Status, declined: Bool, calendarCount: Int, day: CalendarDay,
                        nextLater: CalendarEvent?, offline: Bool) -> CalendarCardState {
        switch status {
        case .off: return declined ? .declined : .ask
        case .needsAccess: return .ask
        case .denied: return .denied
        case .restricted: return .restricted
        case .ready:
            if calendarCount == 0 { return .noCalendars }
            if day.featured == nil { return .clearRestOfDay(next: nextLater) }
            return .events(offline: offline)
        }
    }
}

/// Automation access for one scriptable player (Spotify, Music).
enum ControlAccess: Equatable { case granted, undetermined, denied }

enum NowPlayingCardState: Equatable {
    /// Something plays; `ask` puts "Let Orilio control <app>?" over it the first time.
    case session(ask: String?)
    /// Access to an app was turned off and nothing else plays.
    case revoked(app: String)
    case nothingPlaying(spotify: Bool, music: Bool)
    /// Spotify isn't installed; Music is.
    case spotifyMissing

    static func resolve(sessionApp: String?, access: ControlAccess?, declined: Bool, revokedApps: [String],
                        spotifyInstalled: Bool, musicInstalled: Bool, hasSession: Bool) -> NowPlayingCardState {
        if hasSession {
            // Asked per app, the first time it plays, unless the user said Not now.
            let ask = sessionApp.flatMap { access == .undetermined && !declined ? $0 : nil }
            return .session(ask: ask)
        }
        if let app = revokedApps.first { return .revoked(app: app) }
        if !spotifyInstalled, musicInstalled { return .spotifyMissing }
        return .nothingPlaying(spotify: spotifyInstalled, music: musicInstalled)
    }
}

enum ClipboardCardState: Equatable {
    /// First open: "Keep a clipboard history?" (opt-in, no system prompt).
    case ask
    /// The user said Not now (or turned it off): "Clipboard history is off".
    case off
    /// macOS denies reading other apps' copies.
    case blocked
    /// A password manager is in front: nothing is recorded meanwhile.
    case privacyPaused
    case empty
    case history

    static func resolve(status: ClipboardModule.Status, declined: Bool, isEmpty: Bool, privacyPaused: Bool) -> ClipboardCardState {
        switch status {
        case .off: return declined ? .off : .ask
        case .blocked: return .blocked
        case .on, .paused:
            if privacyPaused { return .privacyPaused }
            return isEmpty ? .empty : .history
        }
    }
}

enum NotesCardState {
    /// The task column shows "All done for today" once there were tasks and none is left.
    static func allDone(_ tasks: [TaskItem]) -> Bool { !tasks.isEmpty && tasks.allSatisfy(\.done) }
}

enum ShelfCardState: Equatable {
    case empty
    /// The first file that isn't where it was (Locate… / Remove).
    case missing(ShelfItem.ID)
    case files

    static func resolve(_ items: [ShelfItem], pending: Int) -> ShelfCardState {
        if items.isEmpty && pending == 0 { return .empty }
        if let missing = items.first(where: { !$0.isAvailable }) { return .missing(missing.id) }
        return .files
    }
}

enum FocusCardState {
    /// A session whose deadline passed more than a minute before Orilio noticed: the Mac slept.
    static func endedWhileAsleep(deadline: Date, noticedAt: Date) -> Bool { noticedAt.timeIntervalSince(deadline) > 60 }
}
