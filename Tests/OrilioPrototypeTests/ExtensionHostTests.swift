// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import CryptoKit
import Foundation
import Testing
@testable import OrilioExtensionKit
@testable import OrilioPrototype

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let extensionsFolder = repo.appending(path: "extensions", directoryHint: .isDirectory)
private let prayerFolder = extensionsFolder.appending(path: "community.prayer-times.orilioext")

private func manifest(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var object: [String: Any] = ["schema": 1, "id": "community.test", "name": "Test", "version": "1.0.0", "author": "Me",
                                 "license": "MIT", "provides": ["widget.island"], "permissions": ["network": ["api.example.com"]]]
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "orilio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ManifestValidationTests {
    @Test func aGoodManifestPasses() throws {
        let m = try ManifestValidator.validate(manifest())
        #expect(m.id == "community.test" && m.settings.isEmpty)
    }

    @Test func missingAndUnknownKeysAreRefused() {
        #expect(throws: ManifestError.missing("license")) { try ManifestValidator.validate(manifest { $0["license"] = nil }) }
        #expect(throws: ManifestError.unknownKey("camera")) { try ManifestValidator.validate(manifest { $0["camera"] = true }) }
        #expect(throws: ManifestError.unknownKey("permissions.clipboard")) {
            try ManifestValidator.validate(manifest { $0["permissions"] = ["clipboard": true] })
        }
    }

    @Test func badDomainsAreRefused() {
        for host in ["https://api.example.com", "*.example.com", "api.example.com/path", "localhost", "api.example.com:8080"] {
            #expect(throws: ManifestError.self) { try ManifestValidator.validate(manifest { $0["permissions"] = ["network": [host]] }) }
        }
    }

    @Test func onlyHTTPSToADeclaredHostIsFetched() {
        let hosts = ["api.example.com"]
        #expect(DomainPolicy.allows(URL(string: "https://api.example.com/v1?q=1")!, hosts: hosts))
        #expect(!DomainPolicy.allows(URL(string: "http://api.example.com/v1")!, hosts: hosts))
        #expect(!DomainPolicy.allows(URL(string: "https://evil.example.com/")!, hosts: hosts))
        #expect(!DomainPolicy.allows(URL(string: "https://api.example.com.evil.com/")!, hosts: hosts))
        #expect(!DomainPolicy.allows(URL(string: "https://user@api.example.com/")!, hosts: hosts))
        #expect(!DomainPolicy.allows(URL(string: "https://api.example.com:8443/")!, hosts: hosts))
    }
}

struct ExtensionContractTests {
    @Test func resultsDecodeWithEitherDateForm() throws {
        let json = #"{"ear":{"trailing":{"style":"countdown","target":"2026-10-28T13:45:00.000Z"}},"island":{"sections":[{"type":"hero","title":"İkindi","countdownTo":"2026-10-28T13:45:00Z"},{"type":"list","rows":[{"title":"Sabah","value":"05:57","state":"past"}]}]}}"#
        let result = try ExtensionResult.decode(Data(json.utf8))
        #expect(result.ear?.trailing?.target == ISO8601DateFormatter().date(from: "2026-10-28T13:45:00Z"))
        #expect(result.island?.sections.count == 2)
    }

    @Test func unknownSectionsAreRefused() {
        #expect(throws: DecodingError.self) { try ExtensionResult.decode(Data(#"{"island":{"sections":[{"type":"html","text":"<b>"}]}}"#.utf8)) }
    }

    @Test func remindersArePlannedSoonestFirstAndUnique() {
        let now = Date()
        let r = { (id: String, s: TimeInterval) in ExtensionResult.Reminder(id: id, date: now.addingTimeInterval(s), title: id) }
        let plan = ReminderPlan.upcoming([r("b", 120), r("past", -60), r("a", 60), r("a", 90)], now: now)
        #expect(plan.map(\.id) == ["a", "b"])
    }
}

@MainActor
struct ExtensionEarPriorityTests {
    private let ear = ExtensionEarContent(extensionID: "community.prayer-times", leading: .init(text: "İkindi"),
                                          trailing: .init(style: "countdown", target: Date().addingTimeInterval(600)))
    private let visible = Set(IslandTab.allCases)

    @Test func aMeetingOrFocusStillWins() {
        let focus = LiveActivityResolver.layout(meeting: nil, focus: .running, transient: nil, nowPlaying: nil, visible: visible,
                                                indicators: Set(CollapsedIndicator.allCases), extensionEar: ear)
        #expect(focus.leading?.kind == .focus)
    }

    @Test func aloneItTakesBothEars() {
        let layout = LiveActivityResolver.layout(meeting: nil, focus: nil, transient: nil, nowPlaying: nil, visible: visible,
                                                 indicators: Set(CollapsedIndicator.allCases), extensionEar: ear)
        #expect(layout.leading?.kind == .extensionEar && layout.trailing?.kind == .extensionEar)
        #expect(ExtensionEarContent.part(ear, side: .leading, withMusic: false)?.text == "İkindi")
        #expect(ExtensionEarContent.part(ear, side: .leading, withMusic: true)?.style == "countdown") // music keeps the right ear
    }

    @Test func aHiddenExtensionsModuleClaimsNothing() {
        let layout = LiveActivityResolver.layout(meeting: nil, focus: nil, transient: nil, nowPlaying: nil, visible: visible.subtracting([.extensions]),
                                                 indicators: Set(CollapsedIndicator.allCases), extensionEar: ear)
        #expect(layout.isIdle)
    }

    @Test func theCountdownRoundsUp() {
        let now = Date()
        // Hours and minutes in words, never "02:55" (which reads as a time of day).
        #expect(ExtensionCountdown.text(to: now.addingTimeInterval(61), from: now) == "2 min")
        #expect(ExtensionCountdown.text(to: now.addingTimeInterval(3_600), from: now) == "1 h")
        #expect(ExtensionCountdown.text(to: now.addingTimeInterval(2 * 3_600 + 55 * 60), from: now) == "2 h 55 min")
        #expect(ExtensionCountdown.text(to: now.addingTimeInterval(-5), from: now) == "0 min")
    }
}

@MainActor
struct ExtensionCatalogTests {
    private func entry(_ edit: (inout CatalogEntry) -> Void = { _ in }) throws -> CatalogEntry {
        var entry = try CatalogIndex.decode(Data(contentsOf: extensionsFolder.appending(path: "catalog.json"))).extensions[0]
        edit(&entry)
        return entry
    }

    @Test func theShippedIndexMatchesItsPackage() throws {
        let entry = try entry()
        #expect(try ExtensionCatalog.verify(prayerFolder, against: entry).id == "community.prayer-times")
    }

    @Test func aPermissionMismatchIsRefused() throws {
        let more = try entry { $0.permissions.network = ["api.example.com"] }
        #expect(throws: CatalogError.mismatch("permissions")) { try ExtensionCatalog.verify(prayerFolder, against: more) }
        let other = try entry { $0.version = "9.0.0" }
        #expect(throws: CatalogError.mismatch("version")) { try ExtensionCatalog.verify(prayerFolder, against: other) }
    }

    @Test func aChecksumMismatchIsRefused() throws {
        let zip = Data("not really a zip".utf8)
        #expect(throws: CatalogError.checksum) { try ExtensionCatalog.unpack(zip, sha256: String(repeating: "0", count: 64)) }
    }

    @Test func aCheckedZipUnpacks() throws {
        let work = scratch()
        let zip = work.appending(path: "p.zip")
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", prayerFolder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let data = try Data(contentsOf: zip)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = try ExtensionCatalog.unpack(data, sha256: sha)
        #expect(try ExtensionPackage.read(folder).id == "community.prayer-times")
    }

    @Test func updatesAndNewPermissions() throws {
        let entry = try entry { $0.version = "9.9.0"; $0.permissions.network.append("api.example.com") }
        let manifest = try ManifestValidator.validate(Data(contentsOf: prayerFolder.appending(path: "orilio-extension.json")))
        var state = ExtensionState()
        state.granted = manifest.permissions
        let installed = InstalledExtension(manifest: manifest, state: state)
        #expect(ExtensionCatalog.hasUpdate(entry, installed: installed))
        #expect(entry.permissions.added(since: state.granted).network == ["api.example.com"])
        #expect(!ExtensionCatalog.hasUpdate(try self.entry(), installed: installed))
    }

    @Test func installAndUninstallLeaveNothingBehind() throws {
        let root = scratch()
        let host = ExtensionHost(store: ExtensionStore(root: root), startsRunner: false)
        let manifest = try ExtensionPackage.read(prayerFolder)
        try host.install(from: prayerFolder, granted: manifest.permissions, local: false)
        host.setSetting(manifest.id, key: "remindBefore", value: .number(5))
        #expect(host.installed.map(\.id) == [manifest.id])
        #expect(host.store.loadState()[manifest.id] != nil)
        host.uninstall(manifest.id)
        #expect(host.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: host.store.folder(manifest.id).path))
        #expect(host.store.loadState()[manifest.id] == nil)
    }
}
