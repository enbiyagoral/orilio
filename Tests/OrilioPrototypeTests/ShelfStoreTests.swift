import AppKit
import Foundation
import Testing
@testable import OrilioPrototype

/// A scratch folder per test, removed afterwards.
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "orilio-store-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    var storeDirectory: URL { root.appending(path: "Store") }
    var receivedDirectory: URL { root.appending(path: "Store/Received") }

    func file(_ name: String, in folder: String = "Files", bytes: Int = 64) -> URL {
        let dir = root.appending(path: folder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    @MainActor func shelf() -> ShelfModel {
        ShelfModel(receivedDirectory: receivedDirectory, store: ShelfStore(directory: storeDirectory))
    }
}

@MainActor
private func settle(until done: () -> Bool) async {
    for _ in 0..<4_000 where !done() { await Task.yield() }
}

@MainActor
private func waitForSave(_ store: URL) async throws {
    let file = store.appending(path: "shelf.json")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) {
        try await Task.sleep(for: .milliseconds(50))
    }
}

struct ShelfStoreTests {
    @Test func savedItemsComeBackWithTheirDetails() async throws {
        let box = Sandbox()
        let url = box.file("Report.pdf", bytes: 4_096)
        let item = try #require(ShelfItem.load(url, origin: .reference))
        let store = ShelfStore(directory: box.storeDirectory)
        try await store.save([item])

        let restored = await store.load()
        #expect(restored.count == 1)
        let back = try #require(restored.first)
        #expect(back.id == item.id)
        #expect(back.name == "Report.pdf")
        #expect(back.size == 4_096)
        #expect(back.origin == .reference)
        #expect(back.isAvailable)
        #expect(back.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
    }

    @Test func aMovedFileIsFollowedByItsBookmark() async throws {
        let box = Sandbox()
        let url = box.file("Notes.txt")
        let item = try #require(ShelfItem.load(url, origin: .reference))
        let moved = box.root.appending(path: "Elsewhere/Renamed.txt")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)

        let found = ShelfStore.resolve(ShelfStore.record(item))
        #expect(found.isAvailable)
        #expect(found.url.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
    }

    @Test func deletedOrTrashedFilesAreUnavailableNotErrors() throws {
        let box = Sandbox()
        let url = box.file("gone.txt")
        let item = try #require(ShelfItem.load(url, origin: .reference))
        try FileManager.default.removeItem(at: url)
        #expect(!ShelfStore.resolve(ShelfStore.record(item)).isAvailable)

        let trashed = box.file("old.txt", in: ".Trash")
        #expect(!ShelfStore.isAvailable(trashed))
    }

    @Test func aMissingOrCorruptFileLoadsAnEmptyShelf() async throws {
        let box = Sandbox()
        let store = ShelfStore(directory: box.storeDirectory)
        #expect(await store.load().isEmpty)
        try FileManager.default.createDirectory(at: box.storeDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: box.storeDirectory.appending(path: "shelf.json"))
        #expect(await store.load().isEmpty)
    }
}

@MainActor
struct ShelfPersistenceTests {
    @Test func theShelfSurvivesARestart() async throws {
        let box = Sandbox()
        let first = box.shelf()
        first.accept(.files([box.file("a.txt"), box.file("b.txt")]), sequence: 1)
        await settle { first.items.count == 2 }
        try await waitForSave(box.storeDirectory)

        let relaunched = box.shelf()
        await relaunched.restore()
        #expect(Set(relaunched.items.map(\.name)) == ["a.txt", "b.txt"])
        #expect(relaunched.items.map(\.id) == first.items.map(\.id))
    }

    @Test func removingNeverDeletesTheUsersFile() async throws {
        let box = Sandbox()
        let shelf = box.shelf()
        let mine = box.file("mine.txt")
        shelf.accept(.files([mine]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        shelf.remove(shelf.items)
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test func removingAReceivedCopyDeletesOnlyOriliosCopy() async throws {
        let box = Sandbox()
        let shelf = box.shelf()
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        shelf.accept(.image(image), sequence: 1)
        await settle { !shelf.items.isEmpty }
        let copy = try #require(shelf.items.first)
        #expect(copy.origin == .received)
        shelf.undoWindow = .milliseconds(50) // the copy goes once Undo is no longer offered
        shelf.remove(copy)
        for _ in 0..<40 where FileManager.default.fileExists(atPath: copy.url.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))
    }

    @Test func aReceivedItemOutsideOriliosFolderIsNeverDeleted() async throws {
        let box = Sandbox()
        let shelf = box.shelf()
        // A saved record claiming to be received, but pointing at a user's file.
        let user = box.file("user.png")
        var forged = try #require(ShelfItem.load(user, origin: .received))
        forged.isAvailable = true
        try await ShelfStore(directory: box.storeDirectory).save([forged])
        await shelf.restore()
        shelf.remove(shelf.items)
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: user.path))
    }

    @Test func pathTraversalCantEscapeOriliosFolder() {
        let root = URL(fileURLWithPath: "/tmp/orilio-root/Received")
        #expect(ShelfModel.isInside(root.appending(path: "ABC"), root))
        #expect(!ShelfModel.isInside(root.appending(path: "../../Documents"), root))
        #expect(!ShelfModel.isInside(root.appending(path: "ABC/../.."), root))
        #expect(!ShelfModel.isInside(root, root)) // never the whole folder
        #expect(!ShelfModel.isInside(URL(fileURLWithPath: "/tmp/orilio-root/ReceivedX/a"), root)) // a sibling with the same prefix
    }

    @Test func availabilityIsRecheckedWhenTheShelfIsShown() async throws {
        let box = Sandbox()
        let shelf = box.shelf()
        let url = box.file("soon-gone.txt")
        shelf.accept(.files([url]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        try FileManager.default.removeItem(at: url)
        shelf.refreshAvailability()
        await settle { shelf.items.first?.isAvailable == false }
        #expect(shelf.items.first?.isAvailable == false)
    }
}

@MainActor
struct ShelfSelectionTests {
    @Test func selectionDecidesWhatAnActionAppliesTo() async {
        let box = Sandbox()
        let shelf = box.shelf()
        shelf.accept(.files([box.file("1"), box.file("2"), box.file("3")]), sequence: 1)
        await settle { shelf.items.count == 3 }
        let (one, two, three) = (shelf.items[0], shelf.items[1], shelf.items[2])

        shelf.select(one.id, extending: false)
        shelf.select(two.id, extending: true)
        #expect(Set(shelf.targets(for: one).map(\.id)) == [one.id, two.id]) // drag a selected tile: all selected
        #expect(shelf.targets(for: three).map(\.id) == [three.id])         // an unselected tile: only itself
        shelf.select(two.id, extending: true)
        #expect(shelf.selection == [one.id])
        shelf.remove(one)
        #expect(shelf.selection.isEmpty)
    }

    @Test func copyPutsFileURLsOnThePasteboard() async throws {
        let box = Sandbox()
        let shelf = box.shelf()
        let url = box.file("copy-me.txt")
        shelf.accept(.files([url]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        let pasteboard = NSPasteboard(name: .init("orilio-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        shelf.copy(shelf.items, to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL) == [url.standardizedFileURL])
    }
}

@MainActor
struct ShelfKeyboardTests {
    @Test func keysDoNothingWithoutASelection() async {
        let box = Sandbox()
        let shelf = box.shelf()
        shelf.accept(.files([box.file("a")]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        for (code, command) in [(UInt16(49), false), (51, false), (8, true)] {
            #expect(shelf.keyAction(keyCode: code, command: command) == nil)
            #expect(!shelf.handleKey(keyCode: code, command: command))
        }
        #expect(shelf.items.count == 1)
    }

    @Test func eachKeyMapsToExactlyOneAction() async {
        let box = Sandbox()
        let shelf = box.shelf()
        shelf.accept(.files([box.file("a")]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        shelf.select(shelf.items[0].id, extending: false)
        // Space previews; it must never remove anything (regression: a focused hidden button once did).
        #expect(shelf.keyAction(keyCode: 49, command: false) == .quickLook)
        #expect(shelf.keyAction(keyCode: 51, command: false) == .remove)
        #expect(shelf.keyAction(keyCode: 117, command: false) == .remove)
        #expect(shelf.keyAction(keyCode: 8, command: true) == .copy)
        #expect(shelf.keyAction(keyCode: 8, command: false) == nil) // a plain "c"
        #expect(shelf.keyAction(keyCode: 49, command: true) == nil) // ⌘Space belongs to Spotlight
    }

    @Test func deleteRemovesOnlyTheSelectionAndKeepsTheFiles() async throws {
        let box = Sandbox()
        let shelf = box.shelf()
        let keep = box.file("keep"), drop = box.file("drop")
        shelf.accept(.files([keep, drop]), sequence: 1)
        await settle { shelf.items.count == 2 }
        let target = try #require(shelf.items.first { $0.name == "drop" })
        shelf.select(target.id, extending: false)
        #expect(shelf.handleKey(keyCode: 51, command: false))
        #expect(shelf.items.map(\.name) == ["keep"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(FileManager.default.fileExists(atPath: drop.path))
    }

    @Test func aBookmarkThatNoLongerResolvesShowsTheMissingState() {
        let record = ShelfStore.Record(id: UUID(), name: "gone.pdf", bookmark: Data("not a bookmark".utf8),
                                       path: "/nonexistent/orilio/gone.pdf", contentType: "com.adobe.pdf", isFolder: false,
                                       size: 10, addedAt: Date(), received: false)
        let item = ShelfStore.resolve(record)
        #expect(!item.isAvailable)
        #expect(ShelfCardState.resolve([item], pending: 0) == .missing(item.id))
    }

    @Test func undoPutsRemovedItemsBackInTheirPlaces() async {
        let box = Sandbox()
        let shelf = box.shelf()
        shelf.accept(.files([box.file("a"), box.file("b"), box.file("c"), box.file("d")]), sequence: 1)
        await settle { shelf.items.count == 4 }
        let before = shelf.items.map(\.name)
        shelf.remove(shelf.items.filter { $0.name == before[1] || $0.name == before[3] })
        #expect(shelf.items.count == 2)
        #expect(shelf.toast?.undoable == true)
        shelf.undoRemove()
        #expect(shelf.items.map(\.name) == before)
        #expect(shelf.toast == nil)
    }

    @Test func draggingOutRemovesUnlessOptionIsHeld() async {
        let box = Sandbox()
        let shelf = box.shelf()
        let file = box.file("report.pdf")
        shelf.accept(.files([file, box.file("other")]), sequence: 1)
        await settle { shelf.items.count == 2 }
        let report = shelf.items.first { $0.name == "report.pdf" }!.id
        shelf.finishDragOut([report], delivered: true, keep: true) // ⌥ held
        #expect(shelf.items.count == 2)
        shelf.finishDragOut([report], delivered: false, keep: false) // dropped nowhere
        #expect(shelf.items.count == 2)
        shelf.finishDragOut([report], delivered: true, keep: false)
        #expect(shelf.items.map(\.name) == ["other"])
        #expect(FileManager.default.fileExists(atPath: file.path)) // the file itself never moves
    }

    @Test func spacePreviewsTheHoveredTileAndClosesThePreview() async {
        let box = Sandbox()
        let shelf = box.shelf()
        shelf.accept(.files([box.file("a.txt")]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        #expect(shelf.keyAction(keyCode: 49, command: false) == nil) // nothing hovered or selected
        shelf.hovered = shelf.items[0].id
        #expect(shelf.handleKey(keyCode: 49, command: false))
        #expect(shelf.previewing == shelf.items[0].id)
        shelf.hovered = nil
        #expect(shelf.handleKey(keyCode: 49, command: false)) // Space again closes it
        #expect(shelf.previewing == nil)
    }

    @Test func receivedCopiesNobodyPointsAtAreSweptAtLaunch() async throws {
        let box = Sandbox()
        let orphan = box.receivedDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: orphan.appending(path: "Image.png").path, contents: Data(count: 4))
        let user = box.file("mine.txt")
        let shelf = box.shelf()
        await shelf.restore()
        for _ in 0..<40 where FileManager.default.fileExists(atPath: orphan.path) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: user.path))
    }
}

struct ShelfCloudAndMetaTests {
    @Test func iCloudStatusMapping() {
        #expect(CloudState.from(isUbiquitous: true, status: .notDownloaded) == .cloudOnly)
        #expect(CloudState.from(isUbiquitous: true, status: .current) == .local)
        #expect(CloudState.from(isUbiquitous: true, status: .downloaded) == .local)
        #expect(CloudState.from(isUbiquitous: false, status: nil) == .local)
        #expect(CloudState.from(isUbiquitous: nil, status: .notDownloaded) == .local) // not in iCloud at all
    }

    @Test func metaLines() {
        #expect(ShelfMeta.line(kind: "PDF", pixels: nil, size: 412_000, folder: "Downloads") == "PDF · 412 KB · from Downloads")
        #expect(ShelfMeta.line(kind: "PNG", pixels: CGSize(width: 2880, height: 1800), size: 1_100_000, folder: "Desktop")
                == "PNG · 2880 × 1800 · \(ByteCountFormatter.string(fromByteCount: 1_100_000, countStyle: .file))") // "1.1 MB", or "1,1 MB"
    }

    @Test func aDragIsRecognizedOnlyWhenTheDragPasteboardChanges() {
        var watch = DragWatch()
        var count = 7
        #expect(watch.event(.leftMouseDown, changeCount: { count }, now: 0) == nil)
        #expect(watch.event(.leftMouseDragged, changeCount: { count }, now: 1) == nil) // selecting text, resizing a window…
        count = 8 // a drag session wrote the drag pasteboard
        #expect(watch.event(.leftMouseDragged, changeCount: { count }, now: 1.01) == nil) // throttled
        #expect(watch.event(.leftMouseDragged, changeCount: { count }, now: 1.2) == .started)
        #expect(watch.event(.leftMouseDragged, changeCount: { count }, now: 1.4) == nil) // once per drag
        #expect(watch.event(.leftMouseUp, changeCount: { count }, now: 2) == .ended)
        #expect(watch.event(.leftMouseUp, changeCount: { count }, now: 3) == nil) // a plain click ends nothing
    }
}
