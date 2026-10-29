// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit

/// What one scriptable desktop player (Spotify, Apple Music) needs to differ by.
struct ScriptablePlayer: Sendable {
    let id: String
    let name: String
    let bundleID: String
    /// Distributed notification the app posts on every play/pause/track change. Needs no permission.
    let notification: String
    /// Returns {state, title, artist, album, duration, position, trackKey, artworkURL} or {"stopped"} or {"error", number, message}.
    let stateScript: String
    /// Returns raw image bytes for the current track, for players that don't expose an artwork URL.
    let artworkScript: String?
    /// Spotify's script reports duration in milliseconds, Music's in seconds.
    let scriptDurationScale: Double

    static let spotify = ScriptablePlayer(
        id: "spotify", name: "Spotify", bundleID: "com.spotify.client",
        notification: "com.spotify.client.PlaybackStateChanged",
        stateScript: stateScript(bundleID: "com.spotify.client", trackKey: "id of t", artworkURL: "artwork url of t"),
        artworkScript: nil, scriptDurationScale: 0.001)

    static let music = ScriptablePlayer(
        id: "music", name: "Music", bundleID: "com.apple.Music",
        notification: "com.apple.Music.playerInfo",
        stateScript: stateScript(bundleID: "com.apple.Music", trackKey: "persistent ID of t", artworkURL: "\"\""),
        artworkScript: """
        if application id "com.apple.Music" is not running then return missing value
        tell application id "com.apple.Music"
            with timeout of 3 seconds
                try
                    return raw data of artwork 1 of current track
                on error
                    return missing value
                end try
            end timeout
        end tell
        """,
        scriptDurationScale: 1)

    /// A script sent while the app quits would launch it again: each one first asks, which never launches.
    private static func stateScript(bundleID: String, trackKey: String, artworkURL: String) -> String {
        """
        if application id "\(bundleID)" is not running then return {"error", "-600", "not running"}
        tell application id "\(bundleID)"
            with timeout of 3 seconds
                try
                    set s to player state as string
                    if s is "stopped" then return {s}
                    set t to current track
                    return {s, name of t, artist of t, album of t, duration of t, player position, \(trackKey), \(artworkURL)}
                on error m number n
                    return {"error", n as string, m}
                end try
            end timeout
        end tell
        """
    }

    func commandScript(_ command: MediaCommand) -> String {
        let verb = switch command {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        case .seek(let to): "set player position to \(String(format: "%.2f", max(0, to)))"
        case .focus: "activate"
        }
        // A busy app must not hold the shared script queue for AppleScript's default two minutes.
        return """
        if application id "\(bundleID)" is not running then error number -600
        tell application id "\(bundleID)"
            with timeout of 3 seconds
                \(verb)
            end timeout
        end tell
        """
    }
}

/// Track data from either source: a notification's userInfo or a state script's result.
struct PlayerInfo: Sendable, Equatable {
    var state: PlaybackState
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var position: TimeInterval?
    var trackKey: String?
    var artworkURL: URL?
}

enum ScriptState: Sendable, Equatable {
    case stopped
    case track(PlayerInfo)
    case failed(MediaError)
}

extension PlayerInfo {
    static func state(_ raw: String?) -> PlaybackState {
        switch raw?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }
    }

    /// Both apps post "Player State", "Name", "Artist", "Album"; duration is in milliseconds.
    /// Spotify adds "Playback Position" and "Track ID"; Music adds "PersistentID".
    init(notification info: [AnyHashable: Any]) {
        func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let ms = (info["Duration"] as? NSNumber ?? info["Total Time"] as? NSNumber)?.doubleValue
        self.init(state: Self.state(info["Player State"] as? String),
                  title: text("Name"), artist: text("Artist"), album: text("Album"),
                  duration: ms.flatMap { $0 > 0 ? $0 / 1000 : nil },
                  position: (info["Playback Position"] as? NSNumber)?.doubleValue,
                  trackKey: text("Track ID") ?? (info["PersistentID"] as? NSNumber)?.stringValue,
                  artworkURL: nil)
    }
}

extension ScriptState {
    init(descriptor d: NSAppleEventDescriptor, durationScale: Double) {
        func text(_ i: Int) -> String? { d.atIndex(i)?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ i: Int) -> Double? { d.atIndex(i).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil } }
        if text(1) == "error" {
            self = .failed(MediaError(scriptErrorNumber: Int(text(2) ?? "") ?? 0, message: text(3) ?? ""))
            return
        }
        let state = PlayerInfo.state(text(1))
        guard state != .stopped, d.numberOfItems >= 8 else { self = .stopped; return }
        self = .track(PlayerInfo(state: state, title: text(2), artist: text(3), album: text(4),
                                 duration: number(5).map { $0 * durationScale },
                                 position: d.atIndex(6)?.doubleValue,
                                 trackKey: text(7), artworkURL: text(8).flatMap(URL.init(string:))))
    }
}

/// Spotify or Apple Music through public mechanisms only: distributed notifications for changes,
/// Apple Events (user-granted Automation permission) for control, position and artwork.
actor ScriptablePlayerProvider: MediaProvider {
    private enum Event: Sendable {
        case info(PlayerInfo), launched, terminated, refresh
    }

    nonisolated let player: ScriptablePlayer
    nonisolated var id: String { player.id }
    nonisolated var displayName: String { player.name }
    nonisolated let updates: AsyncStream<MediaProviderUpdate>
    private let output: AsyncStream<MediaProviderUpdate>.Continuation
    private nonisolated let events: AsyncStream<Event>.Continuation
    private let runner: AppleScriptRunner
    private nonisolated let relay: NotificationRelay

    /// macOS offers no reliable non-prompting permission check (AEDeterminePermissionToAutomateTarget
    /// can block indefinitely), so Orilio remembers a successful Apple Event instead.
    private var permission: AutomationPermission
    private nonisolated var grantedKey: String { "automationGranted.\(player.bundleID)" }
    private var status = MediaProviderStatus.notRunning
    private var info: PlayerInfo?
    private var positionDate = Date()
    private var artworkTrack: String?

    init(_ player: ScriptablePlayer, runner: AppleScriptRunner = .shared) {
        self.player = player
        self.runner = runner
        permission = UserDefaults.standard.bool(forKey: "automationGranted.\(player.bundleID)") ? .granted : .undetermined
        (updates, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (eventStream, events) = AsyncStream.makeStream(of: Event.self)
        self.events = events

        let bundleID = player.bundleID
        relay = NotificationRelay { info in events.yield(.info(PlayerInfo(notification: info))) }
        // AppKit suspends distributed notifications while the app is inactive, and Orilio is
        // never the active app, so delivery must be immediate. Only the selector API offers that.
        DistributedNotificationCenter.default().addObserver(
            relay, selector: #selector(NotificationRelay.receive(_:)),
            name: Notification.Name(player.notification), object: nil, suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, Event.launched),
                              (NSWorkspace.didTerminateApplicationNotification, Event.terminated)] {
            workspace.addObserver(forName: name, object: nil, queue: nil) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == bundleID { events.yield(event) }
            }
        }
        events.yield(.refresh)
        // Providers live as long as the app, so this loop and the observers are never torn down.
        Task { [self] in
            for await event in eventStream { await handle(event) }
        }
    }

    nonisolated func refresh() { events.yield(.refresh) }

    /// Reading the player's state is an Apple Event: while undecided, macOS asks now.
    func requestControl() async {
        guard isRunning else { return }
        await fetchState()
    }

    func perform(_ command: MediaCommand, on sourceID: String) async throws(MediaError) {
        guard sourceID == player.bundleID, info != nil else { throw .sessionGone }
        // Sending an Apple Event to a closed app would launch it. Never do that.
        guard isRunning else { throw .notRunning }
        if command == .focus {
            // Bringing an app forward needs no Apple Event.
            NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first?.activate()
            return
        }
        do {
            _ = try await runner.run(player.commandScript(command)) { _ in true }
            setPermission(.granted)
            await fetchState()
        } catch {
            if error == .permissionDenied { setPermission(.denied); status = .permissionDenied; publish() }
            throw error
        }
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private func handle(_ event: Event) async {
        switch event {
        case .info(let new):
            guard isRunning else { return }
            // A quitting player says "Stopped" last: take it as is, with no script to ask after it.
            if new.state == .stopped { apply(new); return }
            status = permission == .denied ? .permissionDenied : .ready
            if permission == .granted {
                await fetchState() // adds position and artwork the notification lacks
            } else {
                apply(new)
            }
        case .launched:
            status = .ready
            publish()
        case .terminated:
            status = .notRunning
            info = nil
            publish()
        case .refresh:
            guard isRunning else {
                status = .notRunning
                info = nil
                publish()
                return
            }
            switch permission {
            case .granted: status = .ready; await fetchState() // already allowed, so no prompt
            // Re-check a denial too: the user may have allowed Orilio in System Settings since.
            // A script never prompts once a decision exists, so this stays silent either way.
            case .denied: status = .permissionDenied; await fetchState()
            case .undetermined: status = .ready; publish() // wait for a notification; never prompt unasked
            }
        }
    }

    private func fetchState() async {
        let scale = player.scriptDurationScale
        let state: ScriptState
        do {
            state = try await runner.run(player.stateScript) { ScriptState(descriptor: $0, durationScale: scale) }
        } catch {
            state = .failed(error)
        }
        switch state {
        case .stopped:
            setPermission(.granted)
            info = nil
        case .track(let new):
            setPermission(.granted)
            apply(new, publishing: false)
            await loadArtworkIfNeeded()
        case .failed(.permissionDenied):
            setPermission(.denied)
            status = .permissionDenied
        case .failed(.notRunning):
            status = .notRunning
            info = nil
        case .failed:
            break // keep the last good state rather than blanking the island on a transient error
        }
        publish()
    }

    private func setPermission(_ new: AutomationPermission) {
        permission = new
        UserDefaults.standard.set(new == .granted, forKey: grantedKey)
        if new == .granted, status == .permissionDenied { status = .ready } // access was given back
    }

    private func apply(_ new: PlayerInfo, publishing: Bool = true) {
        var merged = new
        if let old = info, old.trackKey == new.trackKey {
            // Notifications carry less than scripts; don't drop what we already know about this track.
            merged.artworkURL = new.artworkURL ?? old.artworkURL
            merged.duration = new.duration ?? old.duration
        }
        info = merged.state == .stopped || merged.title == nil ? nil : merged
        positionDate = Date()
        if publishing { publish() }
    }

    private func loadArtworkIfNeeded() async {
        guard let script = player.artworkScript, let key = info?.trackKey else { return }
        let url = URL(string: "\(ArtworkCache.localScheme)://\(player.id)/\(key)")!
        if artworkTrack != key {
            artworkTrack = key
            let data = try? await runner.run(script) { $0.data.isEmpty ? nil : $0.data }
            if let data = data ?? nil { await ArtworkCache.shared.put(data, for: url) } else { return }
        }
        if info?.trackKey == key { info?.artworkURL = url }
    }

    private func publish() {
        let caps: MediaCapabilities = permission == .denied ? .focus : [.playPause, .next, .previous, .seek, .focus]
        let sessions = info.map { info in
            MediaSessionSnapshot(
                sourceID: player.bundleID, providerID: player.id, sourceName: player.name,
                title: info.title ?? "", artist: info.artist, album: info.album, artworkURL: info.artworkURL,
                state: info.state, duration: info.duration, position: info.position, positionDate: positionDate,
                capabilities: caps, updatedAt: Date(), expiresAt: nil)
        }
        output.yield(MediaProviderUpdate(status: status, sessions: sessions.map { [$0] } ?? []))
    }
}

/// Target for the selector-based observer API.
private final class NotificationRelay: NSObject, Sendable {
    private let handler: @Sendable ([AnyHashable: Any]) -> Void

    init(_ handler: @escaping @Sendable ([AnyHashable: Any]) -> Void) {
        self.handler = handler
    }

    @objc func receive(_ note: Notification) {
        handler(note.userInfo ?? [:])
    }
}
