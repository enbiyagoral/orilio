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
    /// iCloud Drive with Optimize Storage: the file may be only in iCloud.
    var cloud = CloudState.local

    /// Reads the file's metadata. Touches the file system, so call it off the main actor.
    static func load(_ url: URL, origin: Origin, now: Date = Date()) -> ShelfItem? {
        let keys: Set<URLResourceKey> = [.localizedNameKey, .contentTypeKey, .isDirectoryKey, .totalFileSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil } // gone or unreadable
        let isFolder = values.isDirectory ?? false
        return ShelfItem(id: UUID(), url: url, name: values.localizedName ?? url.lastPathComponent,
                         contentType: values.contentType, isFolder: isFolder,
                         size: isFolder ? nil : (values.totalFileSize ?? values.fileSize).map(Int64.init),
                         addedAt: now, origin: origin, bookmark: try? url.bookmarkData(), cloud: CloudState.of(url))
    }
}

/// Where an iCloud Drive file's contents are.
enum CloudState: Equatable, Sendable {
    /// On this Mac (or not in iCloud at all).
    case local
    /// Only in iCloud: opening, previewing or dragging it out downloads it first.
    case cloudOnly
    case downloading

    static func from(isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?) -> CloudState {
        guard isUbiquitous == true, status == .notDownloaded else { return .local }
        return .cloudOnly
    }

    /// Reads the file's iCloud status (no network: the system already knows it).
    static func of(_ url: URL) -> CloudState {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return from(isUbiquitous: values?.isUbiquitousItem, status: values?.ubiquitousItemDownloadingStatus)
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
    /// The item shown in the island's Quick Look (the M5 Shelf design).
    private(set) var previewing: UUID?
    /// The tile under the pointer: Space previews it when nothing is selected.
    var hovered: UUID?
    /// Items that just arrived: they glow for a moment.
    private(set) var recentlyAdded = Set<UUID>()
    /// "3 files added", or "Removed … from Shelf" with Undo.
    private(set) var toast: Toast?

    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let undoable: Bool
    }

    /// The last removal, kept for Undo (with each item's place) until its toast goes.
    @ObservationIgnored private var lastRemoved: [(item: ShelfItem, index: Int)] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// How long "Removed … · Undo" stays.
    @ObservationIgnored var undoWindow: Duration = .seconds(5)

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
        sweepReceived()
    }

    /// Deletes received copies no item points at any more (removed before Orilio last quit, or
    /// dragged out). Only folders inside Orilio's own Received folder.
    private func sweepReceived() {
        let kept = Set(items.filter { $0.origin == .received }.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let root = receivedDirectory
        Task.detached(priority: .utility) {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in folders where !kept.contains(folder.standardizedFileURL.path) && Self.isInside(folder, root) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
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
            if items[index].cloud != .downloading, items[index].cloud != fresh.cloud { items[index].cloud = fresh.cloud }
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

    /// ↑↓←→ between tiles: the selection becomes the one tile moved to.
    func moveSelection(by step: Int) {
        let current = items.first { selection.contains($0.id) }?.id
        selection = ListCursor.moved(current, in: items.map(\.id), by: step).map { [$0] } ?? []
    }

    /// The header's Select: everything, or nothing if everything already is.
    func toggleSelectAll() {
        selection = selection.count == items.count ? [] : Set(items.map(\.id))
    }

    /// What everything on the Shelf takes (the files themselves; folders aren't counted).
    var totalSize: Int64 { items.compactMap(\.size).reduce(0, +) }

    /// What an action on `item` applies to: the whole selection if the item is part of it.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    // MARK: Keyboard

    enum KeyAction: Equatable {
        case quickLook, remove, copy
    }

    /// The shelf's keys, decided explicitly (never by whichever control happens to have focus):
    /// Space previews (the selection, else the hovered tile) and closes the preview, Delete removes
    /// from the shelf, ⌘C copies. Nothing else without a selection.
    func keyAction(keyCode: UInt16, command: Bool) -> KeyAction? {
        if keyCode == 49, !command, previewing != nil || (selection.isEmpty && hovered != nil) { return .quickLook }
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
        case .quickLook:
            if previewing != nil { closePreview() } else if let item = selected.first ?? items.first(where: { $0.id == hovered }) { preview(item) }
        case .remove: remove(selected)
        case .copy: copy(selected)
        }
        return true
    }

    // MARK: Actions

    func open(_ items: [ShelfItem]) {
        download(items)
        for item in items where item.isAvailable { NSWorkspace.shared.open(item.url) }
    }

    // MARK: Quick Look in the island

    func preview(_ item: ShelfItem) {
        guard item.isAvailable else { return }
        download([item])
        previewing = item.id
    }

    func closePreview() { previewing = nil }

    var previewedItem: ShelfItem? { items.first { $0.id == previewing } }

    // MARK: iCloud

    /// Asks iCloud for the files that are only in the cloud. Their status is then checked once a
    /// second until they're here: only while something downloads, never otherwise.
    func download(_ targets: [ShelfItem]) {
        let ids = Set(targets.filter { $0.cloud == .cloudOnly }.map(\.id))
        guard !ids.isEmpty else { return }
        for index in items.indices where ids.contains(items[index].id) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: items[index].url)
            items[index].cloud = .downloading
        }
        watchDownloads()
    }

    @ObservationIgnored private var downloadWatch: Task<Void, Never>?

    private func watchDownloads() {
        guard downloadWatch == nil else { return }
        downloadWatch = Task { [weak self] in
            while let self, self.items.contains(where: { $0.cloud == .downloading }) {
                try? await Task.sleep(for: .seconds(1))
                for index in self.items.indices where self.items[index].cloud == .downloading {
                    let state = CloudState.of(self.items[index].url)
                    if state == .local { self.items[index].cloud = .local }
                }
            }
            self?.downloadWatch = nil
        }
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

    /// Takes items off the shelf, with "Removed … · Undo" for a few seconds. The user's own files
    /// are never touched; a copy that Orilio received for the shelf (from Mail, Photos, a browser)
    /// is Orilio's and is deleted once Undo is no longer offered.
    func remove(_ removed: [ShelfItem]) {
        commitRemoval()
        let ids = Set(removed.map(\.id))
        lastRemoved = items.enumerated().filter { ids.contains($0.element.id) }.map { ($0.element, $0.offset) }
        guard !lastRemoved.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let previewing, ids.contains(previewing) { self.previewing = nil }
        let name = lastRemoved.count == 1 ? lastRemoved[0].item.name : "\(lastRemoved.count) items"
        show(Toast(text: "Removed \(name) from Shelf", undoable: true))
        scheduleSave()
    }

    func remove(_ item: ShelfItem) { remove([item]) }

    /// Puts the last removed items back where they were.
    func undoRemove() {
        let restored = lastRemoved.sorted { $0.index < $1.index }
        lastRemoved = []
        for (item, index) in restored where !items.contains(where: { $0.id == item.id }) {
            items.insert(item, at: min(index, items.count))
        }
        toastTask?.cancel()
        toast = nil
        if !restored.isEmpty { scheduleSave() }
    }

    /// Undo is gone: delete the received copies among the removed items (only Orilio's own folders).
    private func commitRemoval() {
        let ownFolders = lastRemoved.map(\.item).filter { $0.origin == .received }.map { $0.url.deletingLastPathComponent() }
            .filter { Self.isInside($0, receivedDirectory) } // never anything else
        lastRemoved = []
        if !ownFolders.isEmpty {
            Task.detached(priority: .utility) {
                for folder in ownFolders { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    private func show(_ toast: Toast) {
        toastTask?.cancel()
        if !toast.undoable { commitRemoval() } // a new message replaces Undo
        self.toast = toast
        toastTask = Task { [weak self, window = toast.undoable ? undoWindow : .seconds(2)] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toast = nil
            if toast.undoable { self.commitRemoval() }
        }
    }

    /// The header's Clear all…: everything off the Shelf (Undo puts it back).
    func clearAll() { remove(items) }

    /// Tiles dragged into another app leave the Shelf, unless ⌥ was held. A received copy stays on
    /// disk until the next launch: the other app may still be reading it.
    func finishDragOut(_ ids: [UUID], delivered: Bool, keep: Bool) {
        guard delivered, !keep else { return }
        let gone = Set(ids)
        items.removeAll { gone.contains($0.id) }
        selection.subtract(gone)
        scheduleSave()
    }

    /// "Locate…" on a missing file: the shelf points at the file the user picked, in the same place.
    func relocate(_ item: ShelfItem, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), let fresh = ShelfItem.load(url, origin: .reference) else { return }
        items[index] = fresh
        selection.remove(item.id)
        scheduleSave()
    }

    /// True only for a folder strictly inside `root`, after resolving `..` and symbolic links, so a
    /// forged or corrupted record like `Received/../../Documents` can never point the delete elsewhere.
    nonisolated static func isInside(_ folder: URL, _ root: URL) -> Bool {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let root = root.standardizedFileURL.resolvingSymlinksInPath().path
        return folder.hasPrefix(root + "/") && folder != root
    }

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
        guard !new.isEmpty else { return }
        scheduleSave()
        let ids = Set(new.map(\.id))
        recentlyAdded.formUnion(ids)
        show(Toast(text: new.count == 1 ? "1 file added" : "\(new.count) files added", undoable: false))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.recentlyAdded.subtract(ids)
        }
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
