// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI
import Testing
@testable import OrilioPrototype

/// ORILIO_RENDER_STATES=/path/dir swift test --filter StatusCardRender
/// Draws representative cards at the island's content size (and the compact panel) to check
/// they fit: title on one line, body on at most two.
@MainActor
struct StatusCardRender {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_RENDER_STATES"] != nil))
    func renderCards() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_RENDER_STATES"]!)
        let cards: [(String, StatusCard)] = [
            ("ask", StatusCard(tone: .ask(tile: Color(red: 0.43, green: 0.66, blue: 1).opacity(0.16), ink: Color(red: 0.553, green: 0.733, blue: 1)),
                               symbol: "calendar", title: "Show your meetings up here?",
                               detail: "Orilio reads events from calendars already added to this Mac — iCloud, Google, Outlook. Nothing leaves your Mac.",
                               primary: .init("Continue") {}, secondary: .init("Not now") {}, layout: .ask)),
            ("warn", StatusCard(tone: .warn, symbol: "exclamationmark.shield", title: "Calendar access is off",
                                detail: "Orilio can’t see your events until access is turned back on.", primary: .init("Turn on") {})),
            ("empty", StatusCard(tone: .empty, symbol: "music.note", title: "Nothing playing", detail: "Start something and it shows up here.",
                                 primary: .init("Open Spotify") {}, secondary: .init("Open Music") {})),
            ("good", StatusCard(tone: .good, symbol: "moon.zzz", title: "Session ended at 10:42",
                                detail: "Your Mac was asleep, so Orilio stayed quiet.", primary: .init("Start another") {})),
            ("banner", StatusCard(tone: .warn, symbol: "exclamationmark.shield", title: "Orilio can no longer control Spotify",
                                  detail: "Access was turned off. Re-enable it in Privacy & Security › Automation.",
                                  primary: .init("Open System Settings") {}, layout: .banner)),
        ]
        for (name, card) in cards {
            for (size, label) in [(CGSize(width: 660, height: 236), "standard"), (CGSize(width: 520, height: 183), "compact")] {
                let view = card.frame(width: size.width, height: size.height).background(.black)
                    .environment(\.colorScheme, .dark).foregroundStyle(.white)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try #require(renderer.nsImage)
                let tiff = try #require(image.tiffRepresentation)
                let rep = try #require(NSBitmapImageRep(data: tiff))
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: directory.appending(path: "\(name)-\(label).png"))
            }
        }
    }
}
