// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// Messages between the Chrome extension and Orilio (through the native messaging host).
/// One flat shape for every type keeps both ends simple; unused fields are omitted.
struct BridgeMessage: Codable, Equatable, Sendable {
    var v: Int
    var type: String
    /// Which site adapter reported the session; see `BridgeProtocol.sites`.
    var site: String?
    /// Random id of one running browser (kept for its session), so two Chromium browsers never share tab ids.
    var browser: String?
    /// "Google Chrome", "Brave", … sent with `hello`.
    var browserName: String?
    /// "music" or "video".
    var kind: String?
    /// Whether the tab is visible to the user.
    var visible: Bool?
    var tabId: Int?
    var windowId: Int?
    var state: String?
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?
    var duration: Double?
    var position: Double?
    var capabilities: [String]?
    var pwa: Bool?
    var buffering: Bool?
    var id: String?
    var command: String?
    var ok: Bool?
    var error: String?

    init(type: String, tabId: Int? = nil, id: String? = nil, command: String? = nil, position: Double? = nil) {
        v = BridgeProtocol.version
        self.type = type
        self.tabId = tabId
        self.id = id
        self.command = command
        self.position = position
    }
}

enum BridgeProtocol {
    static let version = 1
    static let hostName = "com.enbiyagoral.orilio"
    /// Fixed by the `key` in extensions/chrome/manifest.json.
    static let extensionID = "jpnkibdkjlelnemfnpifoakbglenjnbg"
    static let extensionOrigin = "chrome-extension://\(extensionID)/"
    /// Far above any real message; anything larger is dropped as malformed.
    static let maxMessageBytes = 64 * 1024
    static let maxTextLength = 300
    /// Sessions must be re-confirmed (the tab sends a heartbeat every 25 s) or they expire. Chrome
    /// holds a background tab's timers to about one a minute, so the lifetime spans two of those.
    static let sessionLifetime: TimeInterval = 150
    /// The sites the extension supports, by the adapter id it reports, with the name Orilio shows.
    static let sites = ["youtube-music": "YouTube Music", "youtube": "YouTube", "spotify": "Spotify", "soundcloud": "SoundCloud"]
    /// Cover art hosts of those sites (Google, Spotify, SoundCloud). Anything else is dropped.
    static let artworkHostSuffixes = ["googleusercontent.com", "ggpht.com", "ytimg.com",
                                      "scdn.co", "spotifycdn.com", "sndcdn.com"]

    static func command(_ command: MediaCommand) -> (name: String, position: Double?) {
        switch command {
        case .play: ("play", nil)
        case .pause: ("pause", nil)
        case .togglePlayPause: ("toggle", nil)
        case .next: ("next", nil)
        case .previous: ("previous", nil)
        case .seek(let to): ("seek", max(0, to))
        case .focus: ("focus", nil)
        }
    }

    /// Unique across browsers and stable while that browser runs.
    static func sourceID(browser: String?, tabId: Int) -> String {
        "chrome:\(validBrowserID(browser)):tab:\(tabId)"
    }

    static func validBrowserID(_ id: String?) -> String {
        guard let id, (1...32).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return "default" }
        return id.lowercased()
    }
}

extension BridgeMessage {
    /// A validated snapshot, or nil when the message is not a well-formed, playing-or-paused session.
    func snapshot(providerID: String, receivedAt: Date, browserName: String? = nil) -> MediaSessionSnapshot? {
        guard v == BridgeProtocol.version, type == "session", let tabId, tabId > 0,
              let siteName = BridgeProtocol.sites[site ?? "youtube-music"] else { return nil }
        let playback: PlaybackState
        switch state {
        case "playing": playback = .playing
        case "paused": playback = .paused
        default: return nil
        }
        guard let title = Self.clean(title) else { return nil }

        var capabilities: MediaCapabilities = []
        for name in self.capabilities ?? [] {
            switch name {
            case "playPause": capabilities.insert(.playPause)
            case "next": capabilities.insert(.next)
            case "previous": capabilities.insert(.previous)
            case "seek": capabilities.insert(.seek)
            case "focus": capabilities.insert(.focus)
            default: break // unknown capabilities from a newer extension are ignored, never assumed
            }
        }
        let validDuration = duration.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? $0 : nil }
        let validPosition = position.flatMap { $0.isFinite && $0 >= 0 ? min($0, validDuration ?? $0) : nil }

        return MediaSessionSnapshot(
            sourceID: BridgeProtocol.sourceID(browser: browser, tabId: tabId), providerID: providerID,
            sourceName: pwa == true ? siteName : "\(siteName) · \(Self.clean(browserName).map { String($0.prefix(40)) } ?? "Chrome")",
            title: title, artist: Self.clean(artist), album: Self.clean(album),
            artworkURL: Self.artworkURL(artwork),
            state: playback, duration: validDuration, position: validPosition, positionDate: receivedAt,
            capabilities: capabilities, updatedAt: receivedAt,
            expiresAt: receivedAt.addingTimeInterval(BridgeProtocol.sessionLifetime),
            isBuffering: playback == .playing && buffering == true,
            kind: kind == "video" ? .video : .music,
            isForeground: visible ?? true)
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(BridgeProtocol.maxTextLength))
    }

    static func artworkURL(_ string: String?) -> URL? {
        guard let string, string.count < 2_048, let url = URL(string: string), url.scheme == "https",
              let host = url.host?.lowercased(),
              BridgeProtocol.artworkHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        return url
    }
}

/// Chrome's native messaging framing: a 32-bit length in native byte order (little-endian on Macs), then UTF-8 JSON.
enum NativeMessagingFrame {
    static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        return Data(bytes: &length, count: 4) + payload
    }

    static func length(fromHeader header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Int(UInt32(littleEndian: value))
    }
}
