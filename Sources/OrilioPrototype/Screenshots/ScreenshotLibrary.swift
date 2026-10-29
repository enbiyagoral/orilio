// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation

/// The Screenshots section's state. Metadata is loaded once at launch and updated incrementally;
/// opening the island never rescans the library.
@MainActor @Observable
final class ScreenshotLibrary {
    private(set) var items: [ScreenshotItem] = []
    var newestFirst = true {
        didSet { if newestFirst != oldValue { sort() } }
    }
    private(set) var selection = Set<UUID>()
    /// Imports still running, for the progress indicator.
    private(set) var importing = 0
    /// A short, actionable message about the last import or action.
    private(set) var problem: String?
    private(set) var isLoaded = false

    let store: ScreenshotStore
    let capture: ScreenshotCaptureService
    /// New system screenshots come in on their own (opt-in, `ScreenshotWatcher`).
    private(set) var addsSystemScreenshots = false
    @ObservationIgnored private var watcher: ScreenshotWatcher?
    /// At most this many imports run at once, so a large drop doesn't saturate the disk.
    static let importConcurrency = 2

    init(store: ScreenshotStore = ScreenshotStore(), capture: ScreenshotCaptureService = ScreenshotCaptureService()) {
        self.store = store
        self.capture = capture
    }

    func load() async {
        do {
            items = try await store.all()
            sort()
        } catch {
            problem = "The screenshot library couldn't be opened"
        }
        isLoaded = true
    }

    func imageURL(for item: ScreenshotItem) -> URL { store.imageURL(for: item) }

    /// Starts the watcher if the user turned it on before.
    func startWatchingIfEnabled(_ defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: ScreenshotWatcher.enabledKey) { setAddsSystemScreenshots(true, defaults) }
    }

    func setAddsSystemScreenshots(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: ScreenshotWatcher.enabledKey)
        addsSystemScreenshots = on
        if on {
            if watcher == nil {
                watcher = ScreenshotWatcher(onNew: { [weak self] in self?.importFiles($0) },
                                            onCopied: { [weak self] in self?.importData($0, source: .paste, quiet: true) })
            }
            watcher?.start()
        } else {
            watcher?.stop()
        }
    }

    /// Is there an original outside the library that removing this item leaves in place?
    func hasExternalOriginal(_ item: ScreenshotItem) -> Bool {
        guard let path = item.originalPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: Importing

    /// Imports image files; anything that isn't a readable image is skipped and counted.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run(urls.map { url in { store in try await store.importFile(url) } })
    }

    /// `quiet`: one Orilio found on its own (a copied screenshot): already in the library is no news.
    func importData(_ data: Data, source: ScreenshotItem.Source, quiet: Bool = false) {
        run([{ store in try await store.importData(data, source: source) }], quiet: quiet)
    }

    /// Reads the clipboard only when the user asks (Paste button or ⌘V).
    func paste(from pasteboard: NSPasteboard = .general) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            importFiles(urls)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            importData(data, source: .paste)
        } else {
            problem = "There's no image on the clipboard"
        }
    }

    /// Takes a drop on the island while the Screenshots section is shown.
    func accept(_ content: DropContent, receivingInto folder: URL) {
        switch content {
        case .files(let urls): importFiles(urls)
        case .image(let data): importData(data, source: .file)
        case .promises(let receivers): receive(receivers, into: folder)
        case .unsupported: problem = "That isn't an image"
        }
    }

    func captureScreenshot() {
        Task {
            switch await capture.captureInteractively() {
            case .captured(let url):
                run([{ store in try await store.importFile(url, source: .capture, keepOriginalPath: false) }]) {
                    try? FileManager.default.removeItem(at: url)
                }
            case .cancelled:
                break // the user pressed Esc in the system's selection: nothing to say
            case .failed(let reason):
                problem = reason
            }
        }
    }

    private func receive(_ receivers: [NSFilePromiseReceiver], into folder: URL) {
        for receiver in receivers {
            // One folder per promise: each import removes its own when done, never a sibling's still arriving.
            let incoming = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            guard (try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)) != nil else {
                problem = "Orilio couldn't receive the image"
                continue
            }
            importing += 1
            receiver.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: .main) { [weak self] url, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.importing -= 1
                    if error == nil {
                        // The received file is temporary; the library keeps its own copy.
                        self.run([{ store in try await store.importFile(url, keepOriginalPath: false) }]) {
                            try? FileManager.default.removeItem(at: incoming)
                        }
                    } else {
                        try? FileManager.default.removeItem(at: incoming)
                        self.problem = "An image couldn't be received"
                    }
                }
            }
        }
    }

    /// Runs imports with bounded concurrency and reports the outcome once.
    private func run(_ jobs: [@Sendable (ScreenshotStore) async throws -> ScreenshotItem], quiet: Bool = false,
                     then cleanup: (@Sendable () -> Void)? = nil) {
        importing += jobs.count
        let store = store
        Task {
            var added: [ScreenshotItem] = []
            var duplicates = 0, unreadable = 0
            await withTaskGroup(of: Result<ScreenshotItem, ScreenshotStore.ImportError>.self) { group in
                var queue = jobs[...]
                func next() -> Bool {
                    guard let job = queue.popFirst() else { return false }
                    group.addTask {
                        do { return .success(try await job(store)) } catch let error as ScreenshotStore.ImportError {
                            return .failure(error)
                        } catch { return .failure(.storage) }
                    }
                    return true
                }
                for _ in 0..<Self.importConcurrency where next() {}
                for await result in group {
                    switch result {
                    case .success(let item): added.append(item)
                    case .failure(.duplicate): duplicates += 1
                    case .failure: unreadable += 1
                    }
                    _ = next()
                }
            }
            cleanup?()
            importing -= jobs.count
            insert(added)
            if !quiet { problem = Self.summary(added: added.count, duplicates: duplicates, unreadable: unreadable) }
        }
    }

    static func summary(added: Int, duplicates: Int, unreadable: Int) -> String? {
        var parts: [String] = []
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 was already in the library" : String(localized: "\(duplicates) were already in the library")) }
        if unreadable > 0 { parts.append(unreadable == 1 ? "1 isn't a readable image" : String(localized: "\(unreadable) aren't readable images")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func insert(_ added: [ScreenshotItem]) {
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        sort()
    }

    private func sort() {
        items.sort { newestFirst ? $0.capturedAt > $1.capturedAt : $0.capturedAt < $1.capturedAt }
    }

    // MARK: Selection and actions

    func select(_ id: UUID, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    /// Set by the grid's own (mouse and keyboard) selection.
    func setSelection(_ ids: Set<UUID>) {
        if ids != selection { selection = ids }
    }

    func targets(for item: ScreenshotItem) -> [ScreenshotItem] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    var selectedItems: [ScreenshotItem] { items.filter { selection.contains($0.id) } }

    /// Copies the image itself (pastes into Messages, Mail, documents) and its file.
    func copy(_ items: [ScreenshotItem], to pasteboard: NSPasteboard = .general) {
        let images = items.compactMap { NSImage(contentsOf: imageURL(for: $0)) }
        guard !images.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(images)
    }

    func reveal(_ items: [ScreenshotItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(imageURL))
    }

    /// Removes from the library and moves Orilio's copies to the Trash. Originals stay where they are.
    func remove(_ removed: [ScreenshotItem]) {
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        Task {
            do { try await store.remove(removed) } catch { problem = "Some screenshots couldn't be removed" }
        }
    }

    /// Space previews, Delete removes, ⌘C copies, ⌘V pastes. Decided explicitly, never by focus.
    func handleKey(keyCode: UInt16, command: Bool) -> Bool {
        switch (keyCode, command) {
        case (9, true): paste(); return true // ⌘V works without a selection
        case (49, false) where !selection.isEmpty: QuickLook.show(urls: selectedItems.map(imageURL), toggle: true); return true
        case (51, false) where !selection.isEmpty, (117, false) where !selection.isEmpty: remove(selectedItems); return true
        case (8, true) where !selection.isEmpty: copy(selectedItems); return true
        default: return false
        }
    }
}

/// Decoded thumbnails, bounded in memory. Grid cells ask for one when they appear; NSCache drops
/// the least recently used when the limit is reached, so scrolling a huge library stays flat.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 150 // about 25 MB of 256 px previews; several screens' worth
        return cache
    }()

    final class CGImageBox: @unchecked Sendable { // CGImage is immutable
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func image(for item: ScreenshotItem, in store: ScreenshotStore) async -> CGImageBox? {
        let key = item.id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = await store.ensureThumbnail(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let box = CGImageBox(image)
        cache.setObject(box, forKey: key)
        return box
    }
}

/// Explicit, user-started screenshots through the system's own capture tool (the same selection
/// UI as ⇧⌘4). Nothing is captured without the user pressing the button and choosing an area;
/// macOS asks for Screen Recording permission if it is needed, and handles protected content.
struct ScreenshotCaptureService: Sendable {
    enum Outcome: Sendable, Equatable {
        case captured(URL), cancelled, failed(String)
    }

    var tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    func captureInteractively() async -> Outcome {
        let output = FileManager.default.temporaryDirectory.appending(path: "orilio-capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-i", "-x", output.path] // interactive selection, no shutter sound
        // The handler is set before the tool starts, so a quick exit can't go unnoticed.
        let started = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
        guard started else { return .failed("The system capture tool couldn't start") }
        // Esc in the selection, or a denied permission, leaves no file.
        return FileManager.default.fileExists(atPath: output.path) ? .captured(output) : .cancelled
    }
}
