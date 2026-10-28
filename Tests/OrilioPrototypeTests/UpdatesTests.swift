// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

struct UpdatesTests {
    @Test func featureUpdatesChangeMajorOrMinor() {
        func feature(_ a: String, _ b: String) -> Bool { AppVersion.isFeatureUpdate(from: AppVersion(a), to: AppVersion(b)) }
        #expect(feature("0.4.2", "0.5.0"))
        #expect(feature("0.9", "1.0"))
        #expect(!feature("0.5.0", "0.5.1")) // a patch release stays silent
        #expect(!feature("0.5", "0.5.0"))
        #expect(!feature("0.6.0", "0.5.0")) // never on a downgrade
        #expect(AppVersion("0.10.0") > AppVersion("0.9.9"))
        #expect(AppVersion("1.2") == AppVersion("1.2"))
    }

    @Test func remindersWaitForQuietMomentsAndComeOncePerVersion() {
        #expect(UpdateReminderPolicy.shouldRemind(version: "0.5.1", alreadyReminded: nil, meetingShowing: false, focusActive: false, transientShowing: false))
        #expect(!UpdateReminderPolicy.shouldRemind(version: "0.5.1", alreadyReminded: "0.5.1", meetingShowing: false, focusActive: false, transientShowing: false))
        #expect(UpdateReminderPolicy.shouldRemind(version: "0.5.2", alreadyReminded: "0.5.1", meetingShowing: false, focusActive: false, transientShowing: false))
        #expect(!UpdateReminderPolicy.shouldRemind(version: "0.5.1", alreadyReminded: nil, meetingShowing: true, focusActive: false, transientShowing: false))
        #expect(!UpdateReminderPolicy.shouldRemind(version: "0.5.1", alreadyReminded: nil, meetingShowing: false, focusActive: true, transientShowing: false))
        #expect(!UpdateReminderPolicy.shouldRemind(version: "0.5.1", alreadyReminded: nil, meetingShowing: false, focusActive: false, transientShowing: true))
    }

    @Test func whatsNewOnceAfterAFeatureUpdate() {
        let defaults = UserDefaults(suiteName: "orilio.whatsnew.\(UUID().uuidString)")!
        #expect(!WhatsNewGate.pending(current: "0.4.0", defaults: defaults)) // the very first launch: onboarding instead
        #expect(!WhatsNewGate.pending(current: "0.4.0", defaults: defaults))
        #expect(!WhatsNewGate.pending(current: "0.4.1", defaults: defaults)) // patch
        #expect(WhatsNewGate.pending(current: "0.5.0", defaults: defaults))
        WhatsNewGate.markShown("0.5.0", defaults: defaults)
        #expect(!WhatsNewGate.pending(current: "0.5.0", defaults: defaults)) // shown once
    }

    @Test func whatsNewPendingSurvivesARelaunchBeforeTheClick() {
        let defaults = UserDefaults(suiteName: "orilio.whatsnew.\(UUID().uuidString)")!
        _ = WhatsNewGate.pending(current: "0.4.0", defaults: defaults)
        #expect(WhatsNewGate.pending(current: "0.5.0", defaults: defaults))
        // Quit before clicking the island: it still waits on the next launch.
        #expect(WhatsNewGate.pending(current: "0.5.0", defaults: defaults))
        WhatsNewGate.markShown("0.5.0", defaults: defaults)
        #expect(!WhatsNewGate.pending(current: "0.5.0", defaults: defaults))
    }

    @Test func releaseNoteBullets() {
        let html = "<h2>0.5.1</h2><ul><li>Join button now detects <b>Webex</b> links</li><li> Shelf keeps screenshots &amp; files </li><li></li></ul>"
        #expect(ReleaseNotes.bullets(html) == ["Join button now detects Webex links", "Shelf keeps screenshots & files"])
        #expect(ReleaseNotes.bullets(nil).isEmpty)
    }

    @Test func whatsNewShowsAtMostThreeItems() throws {
        let json = #"{"version":"0.5","items":[{"icon":"a","title":"1","body":""},{"icon":"b","title":"2","body":""},{"icon":"c","title":"3","body":"","tint":"mint"},{"icon":"d","title":"4","body":""}]}"#
        let notes = try #require(WhatsNew.decode(Data(json.utf8)))
        #expect(notes.items.map(\.title) == ["1", "2", "3"])
        #expect(notes.items[2].tint == "mint")
        let bundled = try #require(WhatsNew.decode(Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/WhatsNew.json"))))
        #expect(bundled.items.count == 3)
    }
}
