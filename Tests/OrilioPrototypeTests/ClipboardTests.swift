// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Foundation
import Testing
@testable import OrilioPrototype

/// Stands in for the system pasteboard: tests never touch the user's real clipboard.
@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var readPermission = ClipboardReadPermission.allowed
    var types: [String] = []
    var text: String?
    var image: Data?
    var files: [URL] = []
    private(set) var reads = 0

    func string() -> String? { reads += 1; return text }
    func imageData() -> Data? { reads += 1; return image }
    func fileURLs() -> [URL] { files }

    func write(_ item: ClipItem, image: Data?) -> Int {
        text = item.text
        types = ["public.utf8-plain-text"]
        changeCount += 1
        return changeCount
    }

    func copy(_ text: String, extraTypes: [String] = []) {
        self.text = text
        image = nil
        files = []
        types = ["public.utf8-plain-text"] + extraTypes
        changeCount += 1
    }

    func copyImage(_ data: Data) {
        text = nil
        image = data
        files = []
        types = ["public.png"]
        changeCount += 1
    }
}

@MainActor
private struct Harness {
    let board = FakePasteboard()
    let directory = FileManager.default.temporaryDirectory.appending(path: "orilio-clip-\(UUID().uuidString)")
    let defaults: UserDefaults
    let module: ClipboardModule
    let clock: Clock

    final class Clock { var now = Date(timeIntervalSinceReferenceDate: 800_000_000) }

    init(front: String = "com.apple.TextEdit") {
        defaults = UserDefaults(suiteName: "orilio.clip.\(UUID().uuidString)")!
        let clock = Clock()
        self.clock = clock
        let app = front
        module = ClipboardModule(store: ClipboardStore(directory: directory), pasteboard: board, defaults: defaults,
                                 frontmostApp: { (app, "App") }, now: { clock.now })
    }

    var store: ClipboardStore { ClipboardStore(directory: directory) }
}

private func png() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// Waits for the module's background work (image writes, coalesced saves).
@MainActor
private func settle(_ condition: () -> Bool = { false }) async {
    for _ in 0..<50 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
}

// MARK: - Policy

struct ClipboardPolicyTests {
    @Test func kinds() {
        #expect(ClipboardPolicy.kind(of: "https://github.com/enbiyagoral/orilio") == .link)
        #expect(ClipboardPolicy.kind(of: "kubectl rollout restart deploy/api -n staging") == .code)
        #expect(ClipboardPolicy.kind(of: "AWS_PROFILE=staging") == .code)
        #expect(ClipboardPolicy.kind(of: "Toplantı linkini ekte bulabilirsin") == .text)
        #expect(ClipboardPolicy.kind(of: "javascript:alert(1)") == .text)
        #expect(ClipboardPolicy.kind(of: "see https://example.com today") == .text)
    }

    @Test func privateMarkers() {
        #expect(ClipboardPolicy.isPrivate(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(ClipboardPolicy.isPrivate(types: ["org.nspasteboard.TransientType"]))
        #expect(!ClipboardPolicy.isPrivate(types: ["public.utf8-plain-text"]))
    }

    @Test func pruneKeepsPinnedAndNewest() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func item(_ age: Double, pinned: Bool = false) -> ClipItem {
            ClipItem(id: UUID(), kind: .text, text: "\(age)", imageFileName: nil, imageSize: nil,
                     copiedAt: now.addingTimeInterval(-age), sourceApp: nil, pinned: pinned, contentHash: "\(age)")
        }
        let items = [item(10), item(20), item(30), item(99_999_999, pinned: true), item(200_000)]
        let kept = ClipboardPolicy.prune(items, maxItems: 2, maxAge: 86_400, now: now)
        #expect(kept.map(\.text) == ["10.0", "20.0", "99999999.0"])
    }

    @Test func ages() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(ClipboardPolicy.age(of: now.addingTimeInterval(-30), at: now) == "now")
        #expect(ClipboardPolicy.age(of: now.addingTimeInterval(-360), at: now) == "6 min")
        #expect(ClipboardPolicy.age(of: now.addingTimeInterval(-7_200), at: now) == "2 h")
    }
}

// MARK: - Module

@MainActor
struct ClipboardModuleTests {
    @Test func offByDefaultReadsNothing() async {
        let h = Harness()
        await h.module.start()
        h.board.copy("secret")
        h.module.check()
        #expect(h.module.status == .off)
        #expect(h.module.items.isEmpty)
        #expect(h.board.reads == 0)
    }

    @Test func enablingStartsFromNow() async {
        let h = Harness()
        h.board.copy("copied before turning on")
        await h.module.enable()
        h.module.check()
        #expect(h.module.status == .on)
        #expect(h.module.items.isEmpty)
        #expect(h.board.reads == 0) // the counter didn't move, so no content was read
    }

    @Test func recordsTextLinksAndCode() async {
        let h = Harness()
        await h.module.enable()
        for text in ["hello", "https://github.com/enbiyagoral/orilio", "export AWS_PROFILE=staging"] {
            h.board.copy(text)
            h.module.check()
            h.clock.now.addTimeInterval(1)
        }
        #expect(h.module.visibleItems.map(\.kind) == [.code, .link, .text])
    }

    @Test func recordsImages() async {
        let h = Harness()
        await h.module.enable()
        h.board.copyImage(png())
        h.module.check()
        await settle { !h.module.items.isEmpty }
        let item = try! #require(h.module.items.first)
        #expect(item.kind == .image)
        #expect(item.imageSize == CGSize(width: 4, height: 3))
        #expect(FileManager.default.fileExists(atPath: h.module.imageURL(for: item)!.path))
    }

    @Test func duplicateMovesToTop() async {
        let h = Harness()
        await h.module.enable()
        h.board.copy("a"); h.module.check(); h.clock.now.addTimeInterval(1)
        h.board.copy("b"); h.module.check(); h.clock.now.addTimeInterval(1)
        h.board.copy("a"); h.module.check()
        #expect(h.module.visibleItems.map(\.text) == ["a", "b"])
    }

    @Test func ownCopyIsNotRecordedAgain() async {
        let h = Harness()
        await h.module.enable()
        h.board.copy("a"); h.module.check(); h.clock.now.addTimeInterval(1)
        h.board.copy("b"); h.module.check()
        await h.module.copy(h.module.items[0])
        let reads = h.board.reads
        h.module.check()
        #expect(h.module.items.count == 2)
        #expect(h.board.reads == reads)
    }

    @Test func excludedAppsAndPrivateMarkersAreSkipped() async {
        let h = Harness(front: "com.1password.1password")
        await h.module.enable()
        h.board.copy("hunter2")
        h.module.check()
        #expect(h.module.items.isEmpty)
        #expect(h.board.reads == 0)

        let other = Harness()
        await other.module.enable()
        other.board.copy("hunter2", extraTypes: ["org.nspasteboard.ConcealedType"])
        other.module.check()
        #expect(other.module.items.isEmpty)
    }

    @Test func emptyAndWhitespaceAreSkipped() async {
        let h = Harness()
        await h.module.enable()
        h.board.copy("   \n ")
        h.module.check()
        h.board.types = []
        h.board.changeCount += 1
        h.module.check()
        #expect(h.module.items.isEmpty)
    }

    @Test func pausedRecordsNothing() async {
        let h = Harness()
        await h.module.enable()
        h.module.pause()
        h.board.copy("while paused")
        h.module.check()
        h.module.resume()
        h.module.check()
        #expect(h.module.items.isEmpty)
        #expect(h.module.status == .on)
    }

    @Test func pauseOutlivesARestart() async {
        let h = Harness()
        await h.module.enable()
        h.module.pause()
        let again = ClipboardModule(store: ClipboardStore(directory: h.directory), pasteboard: h.board,
                                    defaults: h.defaults, frontmostApp: { (nil, nil) }, now: { h.clock.now })
        await again.start()
        h.board.copy("after restart")
        again.check()
        #expect(again.status == .paused)
        #expect(again.items.isEmpty)
    }

    @Test func deniedAccessIsBlocked() async {
        let h = Harness()
        h.board.readPermission = .denied
        await h.module.enable()
        h.board.copy("x")
        h.module.check()
        #expect(h.module.status == .blocked)
        #expect(h.module.items.isEmpty)
        #expect(h.board.reads == 0)
    }

    @Test func retentionAndLimit() async {
        let h = Harness()
        await h.module.enable()
        h.module.setMaxItems(10)
        for n in 0..<12 { h.board.copy("item \(n)"); h.module.check(); h.clock.now.addTimeInterval(1) }
        #expect(h.module.items.count == 10)
        h.module.togglePin(h.module.visibleItems.last!)
        h.clock.now.addTimeInterval(8 * 86_400) // past the default 7 days
        h.board.copy("new"); h.module.check()
        #expect(h.module.visibleItems.map(\.text) == ["item 2", "new"])
    }

    @Test func expiredItemsArePurgedWithinTheHourWithoutANewCopy() async {
        let h = Harness()
        await h.module.enable()
        h.module.setRetention(days: 1)
        h.board.copy("old"); h.module.check()
        h.board.copy("pinned"); h.module.check()
        h.module.togglePin(h.module.items.first { $0.text == "pinned" }!)
        h.clock.now.addTimeInterval(86_400 + 3_600) // a day and an hour later, nothing copied since
        h.module.check()
        #expect(h.module.items.map(\.text) == ["pinned"])
    }

    @Test func userExcludedAppsAddToTheBuiltInOnes() async {
        let h = Harness(front: "com.example.bank")
        await h.module.enable()
        h.module.addExcludedApp("com.example.bank")
        h.module.addExcludedApp("com.apple.keychainaccess") // already built in: not added twice
        #expect(h.module.userExcludedApps == ["com.example.bank"])
        #expect(h.module.excludedApps.contains("com.1password.1password"))
        h.board.copy("account 123"); h.module.check()
        #expect(h.module.items.isEmpty)
        h.module.removeExcludedApp("com.example.bank")
        h.board.copy("account 456"); h.module.check()
        #expect(h.module.items.count == 1)
    }

    @Test func clearKeepsPinnedAndDisableDeletesEverything() async {
        let h = Harness()
        await h.module.enable()
        h.board.copy("keep"); h.module.check()
        h.board.copy("drop"); h.module.check()
        h.module.togglePin(h.module.items[0])
        h.module.clear()
        #expect(h.module.items.map(\.text) == ["keep"])
        await h.module.saveNow()
        #expect(FileManager.default.fileExists(atPath: h.directory.path))
        await h.module.disable()
        #expect(h.module.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.directory.path))
    }

    @Test func historySurvivesRestart() async {
        let h = Harness()
        await h.module.enable()
        h.board.copy("persisted"); h.module.check()
        await h.module.saveNow()
        let again = ClipboardModule(store: ClipboardStore(directory: h.directory), pasteboard: FakePasteboard(),
                                    defaults: h.defaults, frontmostApp: { (nil, nil) }, now: { h.clock.now })
        await again.start()
        #expect(again.items.map(\.text) == ["persisted"])
    }

    @Test func corruptOrTamperedStorageLoadsSafely() async throws {
        let h = Harness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: h.directory.appending(path: "history.json"))
        #expect(await h.store.load().isEmpty)

        let id = UUID()
        let tampered = ClipItem(id: id, kind: .image, text: nil, imageFileName: "../../escape.png", imageSize: nil,
                                copiedAt: .now, sourceApp: nil, pinned: false, contentHash: "x")
        try await h.store.save([tampered])
        #expect(await h.store.load().isEmpty)
    }

    @Test func searchAndKeyboardSelection() async {
        let h = Harness()
        await h.module.enable()
        h.board.copy("alpha"); h.module.check(); h.clock.now.addTimeInterval(1)
        h.board.copy("beta"); h.module.check()
        h.module.query = "alp"
        #expect(h.module.visibleItems.map(\.text) == ["alpha"])
        h.module.moveSelection(by: 1) // ↓ from nothing: the first row
        #expect(h.module.selectedItem?.text == "alpha")
        h.module.moveSelection(by: 1) // held at the end
        #expect(h.module.selectedItem?.text == "alpha")
        h.module.requestSearch(typing: "h")
        #expect(h.module.query == "alph")
    }
}

/// QA-0 P1: the excluded-app check looked at the app in front when the 1 s check ran, not when the copy
/// happened, so a password copied in a password manager followed by a quick ⌘-Tab was recorded.
@MainActor
struct ClipboardExcludedSwitchTests {
    @Test func aCopyFromAPasswordManagerStaysOutAfterAQuickSwitch() async {
        let h = Harness() // the check sees TextEdit in front
        await h.module.enable()
        h.module.frontmostChanged("com.1password.1password")
        h.board.copy("hunter2")
        h.module.frontmostChanged("com.apple.TextEdit") // ⌘-Tab before the next check
        h.module.check()
        #expect(h.module.items.isEmpty)
        // Copies made after that are recorded as usual.
        h.board.copy("hello")
        h.module.check()
        #expect(h.module.items.map(\.text) == ["hello"])
    }
}

/// QA-1: a clipboard history that couldn't be read loaded as empty, and the next copy saved over it,
/// pinned items included. It is now put aside first.
@MainActor
struct ClipboardUnreadableHistoryTests {
    @Test func anUnreadableHistoryIsKeptAside() async throws {
        let h = Harness()
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        let original = Data(#"{"version":99,"items":"future format"}"#.utf8)
        try original.write(to: h.directory.appending(path: "history.json"))
        await h.module.enable()
        h.board.copy("after the bad file")
        h.module.check()
        await h.module.saveNow()
        let aside = try FileManager.default.contentsOfDirectory(atPath: h.directory.path).filter { $0.hasPrefix("history-unreadable-") }
        #expect(aside.count == 1)
        #expect(try aside.first.map { try Data(contentsOf: h.directory.appending(path: $0)) } == original)
    }
}
