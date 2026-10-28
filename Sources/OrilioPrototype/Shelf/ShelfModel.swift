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
    /// Where the item is now; updated when its bookmark finds it somewhere else.
    var url: URL
    let name: String
    let contentType: UTType?
    let isFolder: Bool
    let size: Int64?
    let addedAt: Date
    let origin: Origin
    /// Follows the file if it is moved or renamed.
    var bookmark: Data?
    /// False when the file was deleted, moved to the Trash or is on a volume that isn't mounted.
    var isAvailable = true

    /// Reads the file's metadata. Touches the file system, so call it off the main actor.
    static func load(_ url: URL, origin: Origin, now: Date = Date()) -> ShelfItem? {
        let keys: Set<URLResourceKey> = [.localizedNameKey, .contentTypeKey, .isDirectoryKey, .totalFileSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil } // gone or unreadable
        let isFolder = values.isDirectory ?? false
        return ShelfItem(id: UUID(), url: url, name: values.localizedName ?? url.lastPathComponent,
                         contentType: values.contentType, isFolder: isFolder,
                         size: isFolder ? nil : (values.totalFileSize ?? values.fileSize).map(Int64.init),
                         addedAt: now, origin: origin, bookmark: try? url.bookmarkData())
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

/// The File Shelf. Saved by `ShelfStore` when one is given (the app does; tests usually don't).
@MainActor @Observable
final class ShelfModel {
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let name: String
    }

    private(set) var items: [ShelfItem] = []
    /// Selected tiles; dragging a selected tile drags all of them.
    private(set) var selection = Set<UUID>()
    /// Imports still arriving (file promises, image data being written).
    private(set) var pending: [Pending] = []
    /// A short, actionable message about the last problem, cleared by the next success.
    private(set) var problem: String?

    /// Where received content is written: Application Support/Orilio/Shelf/Received.
    let receivedDirectory: URL
    @ObservationIgnored private var handledDrags = Set<Int>()
    @ObservationIgnored private let store: ShelfStore?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Saves are coalesced: a burst of changes writes the file once.
    static let saveDelay: Duration = .milliseconds(300)
    /// At most two promises are fulfilled at once, so a large drop doesn't saturate the disk.
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(receivedDirectory: URL = ShelfModel.defaultReceivedDirectory, store: ShelfStore? = nil) {
        self.receivedDirectory = receivedDirectory
        self.store = store
    }

    /// Loads the saved shelf. Called once at launch; resolving bookmarks happens in the store's actor.
    func restore() async {
        guard let store else { return }
        let saved = await store.load()
        var seen = Set(items.map(\.id))
        items.append(contentsOf: saved.filter { seen.insert($0.id).inserted })
    }

    /// Re-checks where each item is and whether it still exists, once, when the shelf is shown.
    func refreshAvailability() {
        let records = items.map(ShelfStore.record)
        guard !records.isEmpty else { return }
        Task.detached(priority: .utility) {
            let resolved = records.map(ShelfStore.resolve)
            await self.apply(resolved)
        }
    }

    private func apply(_ resolved: [ShelfItem]) {
        var changed = false
        for fresh in resolved {
            guard let index = items.firstIndex(where: { $0.id == fresh.id }) else { continue }
            if items[index].url != fresh.url || items[index].isAvailable != fresh.isAvailable
                || items[index].bookmark != fresh.bookmark {
                items[index].url = fresh.url
                items[index].isAvailable = fresh.isAvailable
                items[index].bookmark = fresh.bookmark
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: Selection

    /// A plain click selects one tile; with ⌘ or ⇧ it adds or removes it.
    func select(_ id: UUID, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    /// What an action on `item` applies to: the whole selection if the item is part of it.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    // MARK: Keyboard

    enum KeyAction: Equatable {
        case quickLook, remove, copy
    }

    /// The shelf's keys, decided explicitly (never by whichever control happens to have focus):
    /// Space previews, Delete removes from the shelf, ⌘C copies. Nothing without a selection.
    func keyAction(keyCode: UInt16, command: Bool) -> KeyAction? {
        guard !selection.isEmpty else { return nil }
        switch (keyCode, command) {
        case (49, false): return .quickLook       // Space
        case (51, false), (117, false): return .remove // Delete, Forward Delete
        case (8, true): return .copy              // ⌘C
        default: return nil
        }
    }

    /// Runs a key on the selection. Returns false if the key isn't the shelf's.
    func handleKey(keyCode: UInt16, command: Bool) -> Bool {
        guard let action = keyAction(keyCode: keyCode, command: command) else { return false }
        let selected = items.filter { selection.contains($0.id) }
        switch action {
        case .quickLook: QuickLook.toggle(selected)
        case .remove: remove(selected)
        case .copy: copy(selected)
        }
        return true
    }

    // MARK: Actions

    func open(_ items: [ShelfItem]) {
        for item in items where item.isAvailable { NSWorkspace.shared.open(item.url) }
    }

    func reveal(_ items: [ShelfItem]) {
        let urls = items.filter(\.isAvailable).map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Puts the files on the clipboard, so Paste in Finder copies them (it never moves them).
    func copy(_ items: [ShelfItem], to pasteboard: NSPasteboard = .general) {
        let urls = items.filter(\.isAvailable).map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
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

    /// Takes items off the shelf. The user's own files are never touched; a copy that Orilio
    /// received for the shelf (from Mail, Photos, a browser) is Orilio's and is deleted with it.
    func remove(_ removed: [ShelfItem]) {
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        let ownFolders = removed.filter { $0.origin == .received }.map { $0.url.deletingLastPathComponent() }
            .filter { $0.path.hasPrefix(receivedDirectory.path + "/") } // only inside Orilio's own folder
        if !ownFolders.isEmpty {
            Task.detached(priority: .utility) {
                for folder in ownFolders { try? FileManager.default.removeItem(at: folder) }
            }
        }
        scheduleSave()
    }

    func remove(_ item: ShelfItem) { remove([item]) }

    private func scheduleSave() {
        guard let store else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.items
            do { try await store.save(snapshot) } catch { self.problem = "The Shelf couldn't be saved" }
        }
    }

    /// Writes pending changes now (used when the app quits).
    func saveNow() async {
        pendingSave?.cancel()
        guard let store else { return }
        try? await store.save(items)
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
        if !new.isEmpty { scheduleSave() }
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
