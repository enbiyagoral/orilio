// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

struct MediaCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let playPause = MediaCapabilities(rawValue: 1 << 0)
    static let next = MediaCapabilities(rawValue: 1 << 1)
    static let previous = MediaCapabilities(rawValue: 1 << 2)
    static let seek = MediaCapabilities(rawValue: 1 << 3)
    /// Bring the source to the front (the app, or the exact browser tab).
    static let focus = MediaCapabilities(rawValue: 1 << 4)
}

enum PlaybackState: Sendable, Equatable {
    case playing, paused, stopped
}

enum MediaKind: Sendable, Equatable {
    case music, video
}

enum MediaCommand: Sendable, Equatable {
    case play, pause, togglePlayPause, next, previous
    case seek(to: TimeInterval)
    case focus

    var requires: MediaCapabilities {
        switch self {
        case .play, .pause, .togglePlayPause: .playPause
        case .next: .next
        case .previous: .previous
        case .seek: .seek
        case .focus: .focus
        }
    }
}

/// Immutable picture of one playing (or paused) source at one moment.
/// One provider can report several sessions, e.g. a browser with music in two tabs.
struct MediaSessionSnapshot: Sendable, Equatable, Identifiable {
    /// Stable per source, unique across providers, e.g. "com.spotify.client" or "chrome:tab:42".
    let sourceID: String
    /// Which provider owns it; commands for this session go only there.
    let providerID: String
    /// Shown to the user: "Spotify", "YouTube Music — Chrome".
    var sourceName: String
    var title: String
    var artist: String?
    var album: String?
    var artworkURL: URL?
    var state: PlaybackState
    var duration: TimeInterval?
    /// Position at `positionDate`. While playing, the UI extrapolates from it instead of polling.
    var position: TimeInterval?
    var positionDate: Date
    var capabilities: MediaCapabilities
    /// Last time the provider confirmed this data.
    var updatedAt: Date
    /// Sources that can vanish silently (browser tabs) set this; it is extended on every heartbeat.
    var expiresAt: Date?
    /// Playing was requested but the player is still loading. Only sources that can tell set it.
    var isBuffering = false
    var kind = MediaKind.music
    /// False for a browser tab the user can't currently see. A background video never takes the
    /// island from music that is playing.
    var isForeground = true

    var id: String { sourceID }

    func isLive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }
}

enum MediaProviderStatus: Sendable, Equatable {
    case ready
    case notRunning
    /// The user declined (or hasn't granted) the Automation / extension permission.
    case permissionDenied
    case unavailable(String)
}

struct MediaProviderUpdate: Sendable, Equatable {
    var status: MediaProviderStatus
    /// The provider's complete current list; anything missing has ended.
    var sessions: [MediaSessionSnapshot]
}

enum MediaError: Error, Equatable {
    case sessionGone
    case unsupported(MediaCommand)
    case notRunning
    case permissionDenied
    case failed(String)
}

/// A source of media sessions: one native app, or one browser via its extension.
/// Implementations must never block the main actor (Apple Events calls belong off it).
protocol MediaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Pushes a full update whenever something changes. Consumed by exactly one coordinator.
    var updates: AsyncStream<MediaProviderUpdate> { get }
    func perform(_ command: MediaCommand, on sourceID: String) async throws(MediaError)
    /// Re-read state now (island opened, Mac woke). Must be cheap and must not prompt the user.
    func refresh()
    /// The user chose Continue on "Let Orilio control …?": the one place that may show the
    /// Automation prompt for this app.
    func requestControl() async
}

extension MediaProvider {
    func refresh() {}
    func requestControl() async {}
}
