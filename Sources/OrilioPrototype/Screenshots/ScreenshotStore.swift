import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// One screenshot in the library. The image itself is Orilio's managed copy; `originalPath` is
/// where it was imported from, if it came from a file (that file is never modified).
struct ScreenshotItem: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case file, paste, capture
    }

    let id: UUID
    let fileName: String
    let originalPath: String?
    let contentHash: String
    let capturedAt: Date
    let importedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let byteSize: Int64
    let source: Source
}

/// The screenshot library on disk:
///
///     Application Support/Orilio/Screenshots/
///         library.sqlite   metadata, one row per screenshot
///         Library/         managed copies, <id>.<ext>
///         Thumbnails/      256 px JPEG previews, <id>.jpg
///
/// SQLite (the system library, no dependency) keeps imports and deletions incremental: adding one
/// screenshot to a library of thousands writes one row, not the whole index.
actor ScreenshotStore {
    enum ImportError: Error, Equatable {
        case unreadable, duplicate, storage
    }

    static let thumbnailPixels = 256

    let directory: URL
    /// Orilio's copies go to the Trash on removal (recoverable). Tests turn this off.
    let trashesCopies: Bool
    var libraryDirectory: URL { directory.appending(path: "Library", directoryHint: .isDirectory) }
    var thumbnailDirectory: URL { directory.appending(path: "Thumbnails", directoryHint: .isDirectory) }
    private var connection: Connection?

    /// Owns the SQLite handle and closes it when the store goes away.
    private final class Connection: @unchecked Sendable { // only ever used from the store's actor
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    init(directory: URL = ScreenshotStore.defaultDirectory, trashesCopies: Bool = true) {
        self.directory = directory
        self.trashesCopies = trashesCopies
    }


    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Orilio/Screenshots", directoryHint: .isDirectory)
    }

    nonisolated func imageURL(for item: ScreenshotItem) -> URL {
        directory.appending(path: "Library/\(item.fileName)")
    }

    /// Managed copies are always named `<id>.<ext>`. Anything else (`../`, another id, a path) is
    /// rejected, so a forged database row can't make "Delete" reach outside the library.
    static func isManagedFileName(_ name: String, id: UUID) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == id.uuidString else { return false }
        return (1...5).contains(parts[1].count) && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    nonisolated func thumbnailURL(for item: ScreenshotItem) -> URL {
        directory.appending(path: "Thumbnails/\(item.id.uuidString).jpg")
    }

    // MARK: Reading

    func all() throws -> [ScreenshotItem] {
        let db = try open()
        var statement: OpaquePointer?
        let sql = "SELECT id, file_name, original_path, content_hash, captured_at, imported_at, width, height, byte_size, source FROM screenshots"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ImportError.storage }
        defer { sqlite3_finalize(statement) }
        var items: [ScreenshotItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
            guard let id = text(0).flatMap(UUID.init), let fileName = text(1), Self.isManagedFileName(fileName, id: id),
                  let hash = text(3) else { continue } // a row that doesn't name its own managed file is ignored
            items.append(ScreenshotItem(
                id: id, fileName: fileName, originalPath: text(2), contentHash: hash,
                capturedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
                importedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)),
                pixelWidth: Int(sqlite3_column_int64(statement, 6)), pixelHeight: Int(sqlite3_column_int64(statement, 7)),
                byteSize: sqlite3_column_int64(statement, 8), source: ScreenshotItem.Source(rawValue: text(9) ?? "") ?? .file))
        }
        return items
    }

    // MARK: Importing

    /// Copies an image file into the library. The original is only read.
    func importFile(_ url: URL, source: ScreenshotItem.Source = .file, keepOriginalPath: Bool = true) throws -> ScreenshotItem {
        guard let info = Self.inspect(url) else { throw ImportError.unreadable }
        let hash = try Self.hash(of: url)
        if try contains(hash: hash) { throw ImportError.duplicate }

        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: libraryDirectory.appending(path: fileName))
        } catch {
            throw ImportError.storage
        }
        let item = ScreenshotItem(
            id: id, fileName: fileName, originalPath: keepOriginalPath ? url.path : nil, contentHash: hash,
            capturedAt: info.capturedAt ?? Self.creationDate(of: url) ?? Date(), importedAt: Date(),
            pixelWidth: info.width, pixelHeight: info.height,
            byteSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0,
            source: source)
        Self.writeThumbnail(from: libraryDirectory.appending(path: fileName), to: thumbnailURL(for: item))
        do {
            try insert(item)
        } catch {
            try? fm.removeItem(at: libraryDirectory.appending(path: fileName))
            try? fm.removeItem(at: thumbnailURL(for: item))
            throw error
        }
        return item
    }

    /// Imports image bytes (a paste, a browser image) by writing them as PNG first.
    func importData(_ data: Data, source: ScreenshotItem.Source) throws -> ScreenshotItem {
        let temp = FileManager.default.temporaryDirectory.appending(path: "orilio-import-\(UUID().uuidString).png")
        guard let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
              let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.storage }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try importFile(temp, source: source, keepOriginalPath: false)
    }

    // MARK: Removing

    /// Removes screenshots from the library and moves Orilio's copies to the Trash (recoverable).
    /// Originals elsewhere on disk are never touched.
    func remove(_ items: [ScreenshotItem]) throws {
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM screenshots WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.storage
        }
        defer { sqlite3_finalize(statement) }
        for item in items {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, item.id.uuidString, -1, Self.transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ImportError.storage }
            if trashesCopies {
                try? FileManager.default.trashItem(at: imageURL(for: item), resultingItemURL: nil)
            } else {
                try? FileManager.default.removeItem(at: imageURL(for: item))
            }
            try? FileManager.default.removeItem(at: thumbnailURL(for: item))
        }
    }

    /// Recreates a missing preview (for example after the thumbnail folder was cleared).
    func ensureThumbnail(for item: ScreenshotItem) -> URL? {
        let url = thumbnailURL(for: item)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        Self.writeThumbnail(from: imageURL(for: item), to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func open() throws -> OpaquePointer {
        if let connection { return connection.handle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(directory.appending(path: "library.sqlite").path, &handle) == SQLITE_OK, let handle else {
            throw ImportError.storage
        }
        let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS screenshots (
            id TEXT PRIMARY KEY,
            file_name TEXT NOT NULL,
            original_path TEXT,
            content_hash TEXT NOT NULL UNIQUE,
            captured_at REAL NOT NULL,
            imported_at REAL NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            byte_size INTEGER NOT NULL,
            source TEXT NOT NULL
        );
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw ImportError.storage
        }
        connection = Connection(handle)
        return handle
    }

    private func contains(hash: String) throws -> Bool {
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM screenshots WHERE content_hash = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.storage
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, hash, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func insert(_ item: ScreenshotItem) throws {
        let db = try open()
        var statement: OpaquePointer?
        let sql = "INSERT INTO screenshots VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ImportError.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, item.id.uuidString, -1, Self.transient)
        sqlite3_bind_text(statement, 2, item.fileName, -1, Self.transient)
        if let original = item.originalPath { sqlite3_bind_text(statement, 3, original, -1, Self.transient) } else { sqlite3_bind_null(statement, 3) }
        sqlite3_bind_text(statement, 4, item.contentHash, -1, Self.transient)
        // Date's own reference, so a stored date reads back exactly.
        sqlite3_bind_double(statement, 5, item.capturedAt.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(statement, 6, item.importedAt.timeIntervalSinceReferenceDate)
        sqlite3_bind_int64(statement, 7, Int64(item.pixelWidth))
        sqlite3_bind_int64(statement, 8, Int64(item.pixelHeight))
        sqlite3_bind_int64(statement, 9, item.byteSize)
        sqlite3_bind_text(statement, 10, item.source.rawValue, -1, Self.transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_CONSTRAINT { throw ImportError.duplicate }
        guard result == SQLITE_DONE else { throw ImportError.storage }
    }

    // MARK: Image helpers (pure, run on the store's executor, off the main actor)

    static func inspect(_ url: URL) -> (width: Int, height: Int, capturedAt: Date?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let captured = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(formatter.date)
        return (width, height, captured)
    }

    static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    /// Streams the file, so a large image is never fully in memory just to be hashed.
    static func hash(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ImportError.unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func writeThumbnail(from image: URL, to thumbnail: URL) {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
