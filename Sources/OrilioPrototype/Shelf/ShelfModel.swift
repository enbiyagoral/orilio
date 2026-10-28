import AppKit
import Observation
import UniformTypeIdentifiers

/// One thing on the File Shelf. Files dropped from Finder are *references*: the shelf never copies,
/// moves or deletes them. Only content that had no file of its own (a promise from Mail or Photos,
/// raw image data from a browser) is written into Orilio's own folder.
struct ShelfItem: Identifiable, Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case reference // the user's file, wherever it lives
        case received  // a copy Orilio received and owns
    }

    let id: UUID
    let url: URL
    let name: String
    let contentType: UTType?
    let isFolder: Bool
    let size: Int64?
    let addedAt: Date
    let origin: Origin

    /// Reads the file's metadata. Touches the file system, so call it off the main actor.
    static func load(_ url: URL, origin: Origin, now: Date = Date()) -> ShelfItem? {
        let keys: Set<URLResourceKey> = [.localizedNameKey, .contentTypeKey, .isDirectoryKey, .totalFileSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil } // gone or unreadable
        let isFolder = values.isDirectory ?? false
        return ShelfItem(id: UUID(), url: url, name: values.localizedName ?? url.lastPathComponent,
                         contentType: values.contentType, isFolder: isFolder,
                         size: isFolder ? nil : (values.totalFileSize ?? values.fileSize).map(Int64.init),
                         addedAt: now, origin: origin)
    }
}

/// What a drag carries, in the order the shelf prefers it.
enum DropContent {
    case files([URL])
    case promises([NSFilePromiseReceiver])
    case image(Data)
    case unsupported

    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// What the shelf can take.
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + imageTypes
    }

    /// What the island listens for. AppKit only reports drags of registered types, so common
    /// content the shelf can't take is registered too, so the island can say so instead of ignoring it.
    static var observedTypes: [NSPasteboard.PasteboardType] {
        acceptedTypes + [.string, .URL, .rtf, .html, .pdf, .color]
    }

    /// Decided from the types alone, while the drag is still moving (no data is read yet).
    static func isSupported(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        let accepted = Set(acceptedTypes)
        return types.contains { accepted.contains($0) }
    }

    static func read(_ pasteboard: NSPasteboard) -> DropContent {
        // Real file URLs first: they are the user's files and need no copying.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            return .promises(receivers)
        }
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) { return .image(data) }
        }
        return .unsupported
    }
}

/// The File Shelf's in-memory state. Persistence arrives in M2.2.
@MainActor @Observable
final class ShelfModel {
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let name: String
    }

    private(set) var items: [ShelfItem] = []
    /// Imports still arriving (file promises, image data being written).
    private(set) var pending: [Pending] = []
    /// A short, actionable message about the last problem, cleared by the next success.
    private(set) var problem: String?

    /// Where received content is written: Application Support/Orilio/Shelf/Received.
    let receivedDirectory: URL
    @ObservationIgnored private var handledDrags = Set<Int>()
    /// At most two promises are fulfilled at once, so a large drop doesn't saturate the disk.
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(receivedDirectory: URL = ShelfModel.defaultReceivedDirectory) {
        self.receivedDirectory = receivedDirectory
    }

    static var defaultReceivedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Orilio/Shelf/Received", directoryHint: .isDirectory)
    }

    /// Accepts one drag. `sequence` is the drag's number, so a drag is never processed twice.
    @discardableResult
    func accept(_ content: DropContent, sequence: Int) -> Bool {
        guard handledDrags.insert(sequence).inserted else { return false }
        switch content {
        case .files(let urls):
            add(urls, origin: .reference)
        case .promises(let receivers):
            receive(receivers)
        case .image(let data):
            save(data)
        case .unsupported:
            problem = "That can't be added to the Shelf"
            return false
        }
        return true
    }

    /// Takes the item off the shelf. The file itself is never touched.
    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    func add(_ urls: [URL], origin: ShelfItem.Origin) {
        var seen = Set(items.map(\.url))
        // Unique within this drop too, keeping the order the user dragged them in.
        let fresh = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let loaded = fresh.compactMap { ShelfItem.load($0, origin: origin) }
            await self.insert(loaded, missing: fresh.count - loaded.count)
        }
    }

    private func insert(_ loaded: [ShelfItem], missing: Int) {
        // Checked again: the same file may have arrived in another drop while metadata was loading.
        var seen = Set(items.map(\.url))
        let new = loaded.filter { seen.insert($0.url).inserted }
        items.insert(contentsOf: new, at: 0) // newest first
        problem = missing > 0 ? (missing == 1 ? "One item couldn't be read" : "\(missing) items couldn't be read") : nil
    }

    private func newReceivingFolder() -> URL? {
        let folder = receivedDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            problem = "Orilio couldn't create its Shelf folder"
            return nil
        }
    }

    private func receive(_ receivers: [NSFilePromiseReceiver]) {
        guard let folder = newReceivingFolder() else { return }
        for receiver in receivers {
            let marker = Pending(name: receiver.fileNames.first ?? "Receiving…")
            pending.append(marker)
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.pending.removeAll { $0.id == marker.id }
                    if error != nil {
                        self.problem = "\(marker.name) couldn't be received"
                    } else {
                        self.add([url], origin: .received)
                    }
                }
            }
        }
    }

    private func save(_ data: Data) {
        guard let folder = newReceivingFolder() else { return }
        let marker = Pending(name: "Image")
        pending.append(marker)
        Task.detached(priority: .userInitiated) {
            // Re-encode to PNG so the shelf keeps one predictable format for raw image drops.
            let url = folder.appending(path: "Image.png")
            let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            let written = (try? png?.write(to: url)) != nil
            await self.finishSaving(marker, url: written ? url : nil)
        }
    }

    private func finishSaving(_ marker: Pending, url: URL?) {
        pending.removeAll { $0.id == marker.id }
        if let url { add([url], origin: .received) } else { problem = "The image couldn't be saved" }
    }
}
