// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation
import Sparkle

// Self-updates through Sparkle 2: every update is EdDSA-signed and verified before it installs.
// Updates found in the background never pop Sparkle's window; they get a quiet reminder instead
// (a one-time "Update ready · Restart" in the island, a mint dot on the menu bar icon).

/// "0.5.1" → major, minor, patch. Pure.
struct AppVersion: Comparable, Equatable {
    let parts: [Int]

    init(_ string: String) {
        parts = string.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    var major: Int { parts.first ?? 0 }
    var minor: Int { parts.count > 1 ? parts[1] : 0 }

    static func < (a: Self, b: Self) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        let pad = { (v: [Int]) in v + Array(repeating: 0, count: count - v.count) }
        return pad(a.parts).lexicographicallyPrecedes(pad(b.parts))
    }

    /// A feature update changes the major or minor number; a patch release only the last one.
    static func isFeatureUpdate(from old: AppVersion, to new: AppVersion) -> Bool {
        new > old && (new.major, new.minor) != (old.major, old.minor)
    }
}

/// When the island may say "Update ready". Pure.
enum UpdateReminderPolicy {
    /// Once per version, and only while nothing else is live: never during a meeting or a focus session.
    static func shouldRemind(version: String, alreadyReminded: String?, meetingShowing: Bool, focusActive: Bool,
                             transientShowing: Bool) -> Bool {
        version != alreadyReminded && isQuiet(meetingShowing: meetingShowing, focusActive: focusActive, transientShowing: transientShowing)
    }

    /// Nothing else is live. A failure notice waits for this instead of being dropped.
    static func isQuiet(meetingShowing: Bool, focusActive: Bool, transientShowing: Bool) -> Bool {
        !meetingShowing && !focusActive && !transientShowing
    }
}

/// The release notes' list items ("<li>Join button now detects Webex links</li>"), as plain text.
enum ReleaseNotes {
    static func bullets(_ html: String?) -> [String] {
        guard let html else { return [] }
        let items = html.components(separatedBy: "<li").dropFirst().compactMap { chunk -> String? in
            guard let start = chunk.firstIndex(of: ">"), let end = chunk.range(of: "</li>") else { return nil }
            let inner = chunk[chunk.index(after: start)..<end.lowerBound]
            let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#39;", with: "’")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return Array(items.prefix(5))
    }
}

/// The updater, as Settings › Updates, the island and the menu bar see it. Sparkle calls both
/// delegates on the main thread; the user driver's protocol just isn't annotated for it.
@MainActor @Observable
final class UpdateModel: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    struct Update: Equatable {
        let version: String
        let size: Int64?
        let date: Date?
        let notes: [String]
    }

    enum Status: Equatable {
        case idle
        case checking
        case available(Update)
        /// "Orilio X wasn't installed": nothing on the Mac was changed.
        case failed(version: String?, reason: String)
        /// This build has no feed or key yet (the placeholders in Info.plist).
        case notConfigured
    }

    enum Channel: String, CaseIterable { case stable, beta }

    enum Keys {
        static let channel = "updates.channel"
        static let remindedVersion = "updates.remindedVersion"
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date?
    /// Found in the background and not acted on: the menu bar dot and "Restart to Update".
    private(set) var waiting: Update?
    /// A background update the island may mention (see `UpdateReminderPolicy`).
    @ObservationIgnored var onReminder: ((Update) -> Void)?
    /// An update that couldn't install: the island's amber one-liner.
    @ObservationIgnored var onFailure: (() -> Void)?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let defaults: UserDefaults
    /// Set while "Check now" runs, so a probe the user cancelled is ignored.
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var lastFound: Update?

    static let shared = UpdateModel()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Placeholder feed or key in Info.plist: Sparkle isn't started, so nothing goes on the network.
    static var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty && !feed.contains("PLACEHOLDER") && !key.contains("PLACEHOLDER")
    }

    func start() {
        guard Self.isConfigured else { return status = .notConfigured }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.sendsSystemProfile = false // no analytics beyond the request itself
        controller.startUpdater()
        self.controller = controller
        lastChecked = controller.updater.lastUpdateCheckDate
    }

    // MARK: Settings

    var automaticChecks: Bool {
        get { access(keyPath: \.status); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; status = status } // re-read by views
    }

    var channel: Channel {
        get { access(keyPath: \.status); return defaults.string(forKey: Keys.channel).flatMap(Channel.init) ?? .stable }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.channel)
            controller?.updater.resetUpdateCycleAfterShortDelay() // the next check reads the new channel
            status = status
        }
    }

    // MARK: Actions

    /// "Check now": asks the feed without Sparkle's window; the card shows what it found.
    func checkNow() {
        guard let updater = controller?.updater, updater.canCheckForUpdates else { return }
        probing = true
        status = .checking
        updater.checkForUpdateInformation()
    }

    /// "Cancel" while checking: the answer, when it comes, is dropped.
    func cancelCheck() {
        probing = false
        status = .idle
    }

    /// "Install and relaunch", "Restart to Update", "Try again": Sparkle's own flow for the update.
    func install() {
        waiting = nil
        controller?.checkForUpdates(nil)
    }

    func downloadFromWebsite() {
        // ponytail: the website isn't public yet; the feed's link page comes with the release setup.
        if let url = (Bundle.main.object(forInfoDictionaryKey: "OrilioWebsiteURL") as? String).flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        }
    }

    var remindedVersion: String? { defaults.string(forKey: Keys.remindedVersion) }
    func markReminded(_ version: String) { defaults.set(version, forKey: Keys.remindedVersion) }

    // MARK: SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { channel == .beta ? ["beta"] : [] }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = Update(version: item.displayVersionString, size: item.contentLength > 0 ? Int64(item.contentLength) : nil,
                            date: item.date, notes: ReleaseNotes.bullets(item.itemDescription))
        lastFound = update
        lastChecked = Date()
        if probing || status == .idle || status == .checking { status = .available(update) }
        probing = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        lastChecked = Date()
        if probing || status == .checking { status = .idle }
        probing = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        probing = false
        let quiet: Set<Int> = [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue),
                               Int(SUError.installationAuthorizeLaterError.rawValue)]
        guard error.domain == SUSparkleErrorDomain, !quiet.contains(error.code) else {
            if status == .checking { status = .idle }
            return
        }
        // Before a download (no network, a bad feed): back to the card; nothing to install failed.
        guard error.code >= Int(SUError.temporaryDirectoryError.rawValue) else {
            if status == .checking { status = .idle }
            return
        }
        status = .failed(version: lastFound?.version, reason: Self.reason(error))
        waiting = nil
        onFailure?()
    }

    private static func reason(_ error: NSError) -> String {
        switch error.code {
        case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue):
            "The download didn’t pass its signature check"
        case Int(SUError.downloadError.rawValue): "The download didn’t finish"
        default: "The update couldn’t be installed"
        }
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Background checks never open Sparkle's window; the island and the menu bar remind instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let found = Update(version: update.displayVersionString, size: update.contentLength > 0 ? Int64(update.contentLength) : nil,
                           date: update.date, notes: ReleaseNotes.bullets(update.itemDescription))
        waiting = found
        if status == .idle { status = .available(found) }
        onReminder?(found)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        waiting = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        waiting = nil
    }
}

// MARK: - What's New

/// What's New after a feature update (`WhatsNew.json` in the app's resources).
struct WhatsNew: Codable, Equatable {
    struct Item: Codable, Equatable {
        /// An SF Symbol.
        let icon: String
        let title: String
        let body: String
        /// "mint", "blue" or nothing (white).
        var tint: String?
    }

    let version: String
    let items: [Item]

    static func bundled() -> WhatsNew? {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// At most three items, as the design shows.
    static func decode(_ data: Data) -> WhatsNew? {
        guard let notes = try? JSONDecoder().decode(WhatsNew.self, from: data) else { return nil }
        return WhatsNew(version: notes.version, items: Array(notes.items.prefix(3)))
    }
}

/// Whether to show What's New, decided once per launch. Pure apart from the defaults.
enum WhatsNewGate {
    enum Keys {
        static let lastLaunchedVersion = "whatsNew.lastLaunchedVersion"
        static let shownVersion = "whatsNew.shownVersion"
        static let pendingVersion = "whatsNew.pendingVersion"
    }

    /// The first launch of a feature update (never the very first launch: that's onboarding; never
    /// a patch release). Records this launch's version.
    static func pending(current: String, defaults: UserDefaults) -> Bool {
        let previous = defaults.string(forKey: Keys.lastLaunchedVersion)
        defaults.set(current, forKey: Keys.lastLaunchedVersion)
        guard defaults.string(forKey: Keys.shownVersion) != current else { return false }
        // Still waiting from a launch that ended before the first click.
        if defaults.string(forKey: Keys.pendingVersion) == current { return true }
        guard let previous, AppVersion.isFeatureUpdate(from: AppVersion(previous), to: AppVersion(current)) else { return false }
        defaults.set(current, forKey: Keys.pendingVersion)
        return true
    }

    static func markShown(_ version: String, defaults: UserDefaults) { defaults.set(version, forKey: Keys.shownVersion) }
}
