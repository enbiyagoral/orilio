// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Foundation
import Testing
@testable import OrilioPrototype

/// A scratch folder per test, removed afterwards.
private final class Scratch {
    let root = FileManager.default.temporaryDirectory.appending(path: "orilio-shelf-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String, bytes: Int = 10) -> URL {
        let url = root.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    func folder(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func pngData() -> Data {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.green.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

@MainActor
private func settle(until done: () -> Bool) async {
    for _ in 0..<2_000 where !done() { await Task.yield() }
}

struct DropContentTests {
    @Test func supportedTypesAreDecidedWithoutReadingData() {
        #expect(DropContent.isSupported([.fileURL]))
        #expect(DropContent.isSupported([.png]))
        #expect(DropContent.isSupported(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }))
        #expect(!DropContent.isSupported([.string]))
        #expect(!DropContent.isSupported([]))
        // Listened for (so the island can refuse them visibly) but never accepted.
        #expect(Set(DropContent.observedTypes).isSuperset(of: DropContent.acceptedTypes))
        #expect(DropContent.observedTypes.contains(.string))
        #expect(!DropContent.isSupported([.string, .URL]))
    }

    @Test func readsFilesBeforeAnythingElse() throws {
        let scratch = Scratch()
        let url = scratch.file("a.txt")
        let pasteboard = NSPasteboard(name: .init("orilio-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        guard case .files(let urls) = DropContent.read(pasteboard) else { Issue.record("expected files"); return }
        #expect(urls.map(\.standardizedFileURL) == [url.standardizedFileURL])
    }

    @Test func readsImageDataAndRefusesText() {
        let pasteboard = NSPasteboard(name: .init("orilio-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)
        guard case .image = DropContent.read(pasteboard) else { Issue.record("expected image"); return }

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        guard case .unsupported = DropContent.read(pasteboard) else { Issue.record("expected unsupported"); return }
    }
}

@MainActor
struct ShelfModelTests {
    @Test func addsReferencesWithoutDuplicatesOrCopies() async {
        let scratch = Scratch()
        let shelf = ShelfModel(receivedDirectory: scratch.root.appending(path: "Received"))
        let file = scratch.file("Report.pdf", bytes: 2_048)
        let folder = scratch.folder("Project")

        #expect(shelf.accept(.files([file, folder, file]), sequence: 1))
        await settle { shelf.items.count == 2 }
        #expect(shelf.items.count == 2)
        #expect(shelf.items.allSatisfy { $0.origin == .reference })
        #expect(shelf.items.first { $0.isFolder }?.size == nil)
        #expect(shelf.items.first { !$0.isFolder }?.size == 2_048)

        shelf.accept(.files([file]), sequence: 2) // the same file again in a later drag
        await settle { false }
        #expect(shelf.items.count == 2)
        // Nothing was copied into Orilio's folder.
        #expect(!FileManager.default.fileExists(atPath: shelf.receivedDirectory.path))
    }

    @Test func oneDragIsHandledOnce() async {
        let scratch = Scratch()
        let shelf = ShelfModel(receivedDirectory: scratch.root.appending(path: "Received"))
        let a = scratch.file("a"), b = scratch.file("b")
        #expect(shelf.accept(.files([a]), sequence: 7))
        #expect(!shelf.accept(.files([b]), sequence: 7)) // the same drag delivered twice
        await settle { shelf.items.count == 1 }
        await settle { false }
        #expect(shelf.items.map(\.name) == ["a"])
    }

    @Test func removingKeepsTheFile() async {
        let scratch = Scratch()
        let shelf = ShelfModel(receivedDirectory: scratch.root.appending(path: "Received"))
        let file = scratch.file("keep.txt")
        shelf.accept(.files([file]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        shelf.remove(shelf.items[0])
        #expect(shelf.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableItemsAreReportedNotAdded() async {
        let scratch = Scratch()
        let shelf = ShelfModel(receivedDirectory: scratch.root.appending(path: "Received"))
        let gone = scratch.root.appending(path: "does-not-exist.txt")
        shelf.accept(.files([gone, scratch.file("ok.txt")]), sequence: 1)
        await settle { !shelf.items.isEmpty }
        #expect(shelf.items.map(\.name) == ["ok.txt"])
        #expect(shelf.problem == "One item couldn't be read")
    }

    @Test func imageDataIsSavedIntoOriliosFolder() async throws {
        let scratch = Scratch()
        let shelf = ShelfModel(receivedDirectory: scratch.root.appending(path: "Received"))
        shelf.accept(.image(pngData()), sequence: 1)
        #expect(shelf.pending.count == 1) // progress is visible while it's written
        await settle { !shelf.items.isEmpty }
        let item = try #require(shelf.items.first)
        #expect(item.origin == .received)
        #expect(item.url.path.hasPrefix(shelf.receivedDirectory.path))
        #expect(NSImage(contentsOf: item.url) != nil)
        #expect(shelf.pending.isEmpty)
    }

    @Test func unsupportedDropExplainsItself() {
        let shelf = ShelfModel(receivedDirectory: FileManager.default.temporaryDirectory.appending(path: "unused"))
        #expect(!shelf.accept(.unsupported, sequence: 1))
        #expect(shelf.problem == "That can't be added to the Shelf")
    }
}

@MainActor
struct DropTargetStateTests {
    private func model() -> IslandModel {
        let model = IslandModel(shelf: ShelfModel(receivedDirectory: FileManager.default.temporaryDirectory.appending(path: "unused")))
        model.isPointerBusy = { false }
        return model
    }

    @Test func dragOpensJustEnoughAndLeavingRestores() {
        let island = model()
        island.dragEntered(valid: true)
        #expect(island.state == .dropTarget)
        #expect(island.dropIsValid)
        island.dragEntered(valid: false) // moving over the island updates validity only
        #expect(!island.dropIsValid)
        island.dragExited()
        #expect(island.state == .collapsed)

        island.tap()
        island.dragEntered(valid: true)
        island.dragExited()
        #expect(island.state == .pinned) // an open controller stays open
    }

    @Test func dropShowsTheShelfWithoutTakingFocus() {
        let island = model()
        var focusAtPin: Bool?
        island.onWillChangeState = { [unowned island] state in
            if state == .pinned { focusAtPin = island.pinTakesFocus }
        }
        island.dragEntered(valid: true)
        island.dropped(.unsupported, sequence: 1)
        #expect(island.state == .pinned)
        #expect(island.tab == .shelf)
        #expect(focusAtPin == false)
        #expect(island.pinTakesFocus) // a later click pins with focus again
    }

    @Test func dropZoneIsSmallerThanTheFullPanel() {
        let g = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                    auxLeftWidth: 662, auxRightWidth: 664, menuBarHeight: 32)
        #expect(g.size(for: .dropTarget).height < g.size(for: .pinned).height)
        #expect(g.size(for: .dropTarget).width >= g.collapsed.width)
    }
}
