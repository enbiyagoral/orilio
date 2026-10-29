// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import UniformTypeIdentifiers

/// Persists the File Shelf in Application Support/Orilio/Shelf/shelf.json.
///
/// Each item keeps a bookmark, not just a path: a bookmark follows a file that the user moves or
/// renames. Orilio isn't sandboxed, so plain bookmarks are enough; a sandboxed build would need
/// `.withSecurityScope` bookmarks and start/stopAccessing calls around each use.
/// A shelf is a short list, so one JSON file written atomically is the right size of tool.
actor ShelfStore {
    struct Record: Codable, Equatable {
        var id: UUID
        var name: String
        var bookmark: Data?
        var path: String
        var contentType: String?
        var isFolder: Bool
        var size: Int64?
        var addedAt: Date
        var received: Bool
    }

    private struct File: Codable {
        var version = 1
        var items: [Record]
    }

    let fileURL: URL
    /// The saved shelf was there but couldn't be read: it was put aside (or, failing that, saving is
    /// off), and the received copies it pointed at must not be swept.
    private(set) var unreadable = false
    private var saveBlocked = false

    init(directory: URL = ShelfStore.defaultDirectory) {
        fileURL = directory.appending(path: "shelf.json")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Orilio/Shelf", directoryHint: .isDirectory)
    }

    /// The saved shelf, with every item's location and availability checked now.
    func load() -> [ShelfItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) else {
            unreadable = true
            let aside = fileURL.deletingLastPathComponent().appending(path: "shelf-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            if (try? FileManager.default.moveItem(at: fileURL, to: aside)) == nil { saveBlocked = true }
            return []
        }
        return file.items.map(Self.resolve)
    }

    func save(_ items: [ShelfItem]) throws {
        guard !saveBlocked else { throw CocoaError(.fileWriteNoPermission) } // never over a shelf we couldn't read
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = File(items: items.map(Self.record))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    static func record(_ item: ShelfItem) -> Record {
        Record(id: item.id, name: item.name, bookmark: item.bookmark, path: item.url.path,
               contentType: item.contentType?.identifier, isFolder: item.isFolder, size: item.size,
               addedAt: item.addedAt, received: item.origin == .received)
    }

    /// Finds where an item is now. Never throws: a file that can't be found is simply unavailable.
    static func resolve(_ record: Record) -> ShelfItem {
        var url = URL(fileURLWithPath: record.path)
        var bookmark = record.bookmark
        if let data = record.bookmark {
            var stale = false
            if let found = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = found
                if stale { bookmark = (try? found.bookmarkData()) ?? data } // refreshed for next time
            }
        }
        return ShelfItem(id: record.id, url: url, name: record.name, contentType: record.contentType.flatMap(UTType.init),
                         isFolder: record.isFolder, size: record.size, addedAt: record.addedAt,
                         origin: record.received ? .received : .reference, bookmark: bookmark,
                         isAvailable: isAvailable(url), cloud: CloudState.of(url))
    }

    /// Present and not in the Trash. Bookmarks follow a file into the Trash, which isn't "available".
    static func isAvailable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return !url.pathComponents.contains(".Trash")
    }
}
