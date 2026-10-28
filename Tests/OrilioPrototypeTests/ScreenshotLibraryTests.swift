import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OrilioPrototype

/// A scratch library and some images, removed afterwards.
private final class Workspace {
    let root = FileManager.default.temporaryDirectory.appending(path: "orilio-shots-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func store() -> ScreenshotStore { ScreenshotStore(directory: root.appending(path: "Library"), trashesCopies: false) }

    @MainActor func library(capture: ScreenshotCaptureService = ScreenshotCaptureService()) -> ScreenshotLibrary {
        ScreenshotLibrary(store: store(), capture: capture)
    }

    /// A PNG whose content is unique per seed: a black block of seed-dependent size on white.
    /// (Close colors aren't enough: color matching can map neighbors to the same bytes.)
    func image(_ name: String, seed: Int, width: Int = 64, height: Int = 40) -> URL {
        let url = root.appending(path: name)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let span = width - 1
        context.fill(CGRect(x: 0, y: 0, width: seed % span + 1, height: min(height, seed / span + 1)))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    func junk(_ name: String) -> URL {
        let url = root.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data("not an image".utf8))
        return url
    }
}

@MainActor
private func settle(_ library: ScreenshotLibrary, until done: () -> Bool) async {
    for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

struct ScreenshotStoreTests {
    @Test func importKeepsTheOriginalAndMakesACopyAndThumbnail() async throws {
        let ws = Workspace()
        let store = ws.store()
        let original = ws.image("Screenshot.png", seed: 1, width: 1_200, height: 800)
        let before = try Data(contentsOf: original)

        let item = try await store.importFile(original)
        #expect(item.pixelWidth == 1_200 && item.pixelHeight == 800)
        #expect(item.originalPath == original.path)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(for: item).path))
        #expect(try Data(contentsOf: original) == before) // the original is only read
        let thumb = try #require(CGImageSourceCreateWithURL(store.thumbnailURL(for: item) as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyPixelWidth] as? Int ?? .max) <= ScreenshotStore.thumbnailPixels)
    }

    @Test func duplicatesAndNonImagesAreRefused() async throws {
        let ws = Workspace()
        let store = ws.store()
        let a = ws.image("a.png", seed: 5)
        _ = try await store.importFile(a)
        let copy = ws.root.appending(path: "copy of a.png")
        try FileManager.default.copyItem(at: a, to: copy) // same content, different name
        await #expect(throws: ScreenshotStore.ImportError.duplicate) { try await store.importFile(copy) }
        await #expect(throws: ScreenshotStore.ImportError.unreadable) { try await store.importFile(ws.junk("broken.png")) }
        #expect(try await store.all().count == 1)
    }

    @Test func theLibrarySurvivesARestart() async throws {
        let ws = Workspace()
        let first = try await ws.store().importFile(ws.image("x.png", seed: 9))
        let reopened = try await ws.store().all() // a new store, like a relaunch
        #expect(reopened == [first])
    }

    @Test func removingDeletesOnlyOriliosCopy() async throws {
        let ws = Workspace()
        let store = ws.store()
        let original = ws.image("keep.png", seed: 3)
        let item = try await store.importFile(original)
        try await store.remove([item])
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(for: item).path))
        #expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(for: item).path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try await store.all().isEmpty)
    }

    @Test func pastedDataHasNoOriginalPath() async throws {
        let ws = Workspace()
        let data = try Data(contentsOf: ws.image("p.png", seed: 11))
        let item = try await ws.store().importData(data, source: .paste)
        #expect(item.originalPath == nil)
        #expect(item.source == .paste)
        await #expect(throws: ScreenshotStore.ImportError.unreadable) {
            try await ws.store().importData(Data("nope".utf8), source: .paste)
        }
    }

    @Test func forgedFileNamesAreRejected() {
        let id = UUID()
        #expect(ScreenshotStore.isManagedFileName("\(id.uuidString).png", id: id))
        #expect(!ScreenshotStore.isManagedFileName("../../Documents/thesis.pdf", id: id))
        #expect(!ScreenshotStore.isManagedFileName("\(UUID().uuidString).png", id: id)) // another item's file
        #expect(!ScreenshotStore.isManagedFileName("\(id.uuidString).png/../../x", id: id))
        #expect(!ScreenshotStore.isManagedFileName("\(id.uuidString)", id: id))
    }

    @Test func aForgedRowCantTrashAFileOutsideTheLibrary() async throws {
        let ws = Workspace()
        let store = ws.store()
        _ = try await store.importFile(ws.image("real.png", seed: 31)) // creates the database
        let victim = ws.image("victim.png", seed: 32)
        // Tamper with the database: a row whose file name walks out of the library to the victim.
        let db = ws.root.appending(path: "Library/library.sqlite").path
        let sql = "INSERT INTO screenshots VALUES ('\(UUID().uuidString)', '../../victim.png', NULL, 'forged', 0, 0, 1, 1, 1, 'file');"
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        tool.arguments = [db, sql]
        try tool.run()
        tool.waitUntilExit()

        let loaded = try await ws.store().all()
        #expect(loaded.count == 1) // the forged row is ignored, so nothing can act on it
        try await ws.store().remove(loaded)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func aMissingThumbnailIsRecreated() async throws {
        let ws = Workspace()
        let store = ws.store()
        let item = try await store.importFile(ws.image("t.png", seed: 21))
        try FileManager.default.removeItem(at: store.thumbnailURL(for: item))
        #expect(await store.ensureThumbnail(for: item) != nil)
    }
}

@MainActor
struct ScreenshotLibraryModelTests {
    @Test func importsReportDuplicatesAndBrokenFiles() async {
        let ws = Workspace()
        let library = ws.library()
        let a = ws.image("a.png", seed: 1)
        library.importFiles([a, ws.image("b.png", seed: 2), ws.junk("c.png")])
        await settle(library) { library.items.count == 2 && library.importing == 0 }
        library.importFiles([a])
        await settle(library) { library.problem?.contains("already") == true }
        #expect(library.items.count == 2)
        #expect(library.problem == "1 was already in the library")
        #expect(ScreenshotLibrary.summary(added: 1, duplicates: 0, unreadable: 2) == "2 aren't readable images")
        #expect(ScreenshotLibrary.summary(added: 3, duplicates: 0, unreadable: 0) == nil)
    }

    @Test func sortsByCaptureDate() async throws {
        let ws = Workspace()
        let older = ws.image("old.png", seed: 1), newer = ws.image("new.png", seed: 2)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: newer.path)
        let library = ws.library()
        library.importFiles([older, newer])
        await settle(library) { library.items.count == 2 }
        #expect(library.items.map(\.capturedAt.timeIntervalSince1970) == [2_000_000, 1_000_000])
        library.newestFirst = false
        #expect(library.items.map(\.capturedAt.timeIntervalSince1970) == [1_000_000, 2_000_000])
    }

    @Test func pasteReadsOnlyWhenAskedAndExplainsAnEmptyClipboard() async throws {
        let ws = Workspace()
        let library = ws.library()
        let pasteboard = NSPasteboard(name: .init("orilio-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        library.paste(from: pasteboard)
        #expect(library.problem == "There's no image on the clipboard")

        pasteboard.clearContents()
        pasteboard.setData(try Data(contentsOf: ws.image("clip.png", seed: 40)), forType: .png)
        library.paste(from: pasteboard)
        await settle(library) { !library.items.isEmpty }
        #expect(library.items.first?.source == .paste)
    }

    @Test func keysActOnTheSelectionOnly() async {
        let ws = Workspace()
        let library = ws.library()
        library.importFiles([ws.image("k1.png", seed: 51), ws.image("k2.png", seed: 52)])
        await settle(library) { library.items.count == 2 }
        #expect(!library.handleKey(keyCode: 51, command: false)) // Delete with nothing selected
        library.select(library.items[0].id, extending: false)
        #expect(library.handleKey(keyCode: 51, command: false))
        #expect(library.items.count == 1)
        #expect(!library.handleKey(keyCode: 8, command: false)) // a plain "c"
    }

    @Test func captureImportsTheShotAndCancellingIsSilent() async throws {
        let ws = Workspace()
        let fixture = ws.image("captured.png", seed: 77)
        // A stand-in for /usr/sbin/screencapture: copies a fixture to the requested path (its 3rd argument).
        let tool = ws.root.appending(path: "fake-capture.sh")
        try "#!/bin/sh\ncp '\(fixture.path)' \"$3\"\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let library = ws.library(capture: ScreenshotCaptureService(tool: tool))
        library.captureScreenshot()
        await settle(library) { !library.items.isEmpty }
        #expect(library.items.first?.source == .capture)
        #expect(library.items.first?.originalPath == nil)

        let cancelling = ScreenshotCaptureService(tool: URL(fileURLWithPath: "/usr/bin/true")) // leaves no file
        #expect(await cancelling.captureInteractively() == .cancelled)
    }
}

@MainActor
struct ScreenshotIslandTests {
    @Test func dropsGoToTheLibraryOnlyWhenItIsShown() async {
        let ws = Workspace()
        let library = ws.library()
        let shelf = ShelfModel(receivedDirectory: ws.root.appending(path: "Received"))
        let island = IslandModel(shelf: shelf, library: library)
        island.isPointerBusy = { false }

        island.dragEntered(valid: true) // from the collapsed island
        #expect(!island.dropGoesToScreenshots)
        island.dragExited()

        island.tap()
        island.tab = .shelf
        island.shelfSection = .screenshots
        #expect(island.wantsTallPanel)
        island.dragEntered(valid: true)
        #expect(island.dropGoesToScreenshots)
        island.dropped(.files([ws.image("drop.png", seed: 90)]), sequence: 1)
        await settle(library) { !library.items.isEmpty }
        #expect(library.items.count == 1)
        #expect(shelf.items.isEmpty)
    }

    @Test func reopeningSizesTheWindowForTheStateBeingEntered() {
        let island = IslandModel()
        island.isPointerBusy = { false }
        island.tab = .shelf
        island.shelfSection = .screenshots
        var tallAtResize: Bool?
        island.onWillChangeState = { [unowned island] state in tallAtResize = island.isTall(state) }
        island.tap() // collapsed -> pinned, straight onto the Screenshots grid
        #expect(tallAtResize == true) // regression: the window was sized for the old (collapsed) state
    }

    @Test func anOutsidePressThatBecomesADragIsNotAClick() {
        #expect(IslandWindowController.isClick(from: NSPoint(x: 100, y: 100), to: NSPoint(x: 102, y: 101)))
        #expect(!IslandWindowController.isClick(from: NSPoint(x: 100, y: 100), to: NSPoint(x: 400, y: 900)))
    }

    @Test func theTallPanelNeverExceedsTheScreen() {
        var g = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                    auxLeftWidth: 662, auxRightWidth: 664, menuBarHeight: 32)
        g.usableHeight = 950
        #expect(g.size(for: .pinned, tall: true).height == 32 + IslandGeometry.tallHeight)
        g.usableHeight = 260 // a small display
        #expect(g.size(for: .pinned, tall: true).height <= 260 + 32 - IslandGeometry.shadowMargin * 2 + 0.5)
        #expect(g.size(for: .pinned, tall: true).height >= g.full.height) // never smaller than the normal panel
    }
}

/// Run with ORILIO_PERF=1 swift test --filter ScreenshotScaleTests
struct ScreenshotScaleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_PERF"] == "1"))
    func importAndReloadAThousandScreenshots() async throws {
        let ws = Workspace()
        let store = ws.store()
        let urls = (0..<1_000).map { ws.image("s\($0).png", seed: $0 + 1_000, width: 1_440, height: 900) }
        let clock = ContinuousClock()
        let imported = try await clock.measure {
            for url in urls { _ = try await store.importFile(url) }
        }
        var count = 0
        let reloaded = try await clock.measure { count = try await ws.store().all().count }
        #expect(count == 1_000)
        print("PERF import 1000 (1440×900 PNG): \(imported); reload metadata: \(reloaded)")
    }
}

/// Fills the real library for a manual scrolling test: ORILIO_POPULATE=1000 swift test --filter ScreenshotPopulate
/// Remove afterwards by deleting ~/Library/Application Support/Orilio/Screenshots.
struct ScreenshotPopulate {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_POPULATE"] != nil))
    func populateTheRealLibrary() async throws {
        let count = Int(ProcessInfo.processInfo.environment["ORILIO_POPULATE"] ?? "") ?? 0
        let ws = Workspace()
        let store = ScreenshotStore()
        for index in 0..<count {
            _ = try await store.importFile(ws.image("Screenshot \(index).png", seed: index + 5_000, width: 1_440, height: 900))
        }
        let clock = ContinuousClock()
        var loaded = 0
        let reload = try await clock.measure { loaded = try await ScreenshotStore().all().count }
        print("POPULATED \(loaded) reload \(reload)")
    }
}
