// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// What the playback controls show between a click and the source's answer.
/// Clicks respond at once; the source has the final word; failures roll back.
struct ControlFeedback: Equatable {
    enum Action: Hashable {
        case playPause, skip, seek
    }

    /// How long an unconfirmed play/pause guess may stay on screen.
    static let expectationLifetime: Duration = .seconds(1.5)
    static let failureLifetime: Duration = .seconds(3)

    private(set) var inFlight: Set<Action> = []
    /// The play state the user just asked for, shown until the source confirms it.
    private(set) var expectedPlaying: Bool?
    private(set) var failure: String?

    /// Starts an action. Returns false while the same action is still running, so rapid
    /// clicks don't send it twice.
    mutating func begin(_ action: Action, expectingPlaying playing: Bool? = nil) -> Bool {
        guard !inFlight.contains(action) else { return false }
        inFlight.insert(action)
        failure = nil
        if let playing { expectedPlaying = playing }
        return true
    }

    mutating func finish(_ action: Action, error: String?) {
        inFlight.remove(action)
        guard let error else { return }
        failure = error
        if action == .playPause { expectedPlaying = nil } // roll back the guess
    }

    /// The source reported its state. A report that matches the guess ends it; an older,
    /// contradicting report is ignored until `expire()`.
    mutating func confirm(playing: Bool) {
        if expectedPlaying == playing { expectedPlaying = nil }
    }

    /// Called when `expectationLifetime` has passed without confirmation: show the source's truth.
    mutating func expire() {
        if !inFlight.contains(.playPause) { expectedPlaying = nil }
    }

    mutating func clearFailure() {
        failure = nil
    }

    func isPlaying(actual: Bool) -> Bool {
        expectedPlaying ?? actual
    }

    static func message(for error: MediaError, source: String) -> String {
        switch error {
        case .notRunning: String(localized: "\(source) isn't running")
        case .permissionDenied: String(localized: "Orilio isn't allowed to control \(source)")
        case .sessionGone: String(localized: "\(source) stopped playing")
        case .unsupported: String(localized: "\(source) can't do that")
        case .failed(let reason) where reason.contains("respond"): String(localized: "\(source) isn't responding")
        case .failed: String(localized: "Couldn't reach \(source)")
        }
    }
}
