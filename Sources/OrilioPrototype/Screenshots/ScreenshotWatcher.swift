// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit

/// Adds screenshots taken with the system shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5) to the library as they are
/// saved, and the ones copied to the clipboard instead. Off until the user turns it on; screenshots
/// from before are left alone.
///
/// Spotlight tags saved ones (`kMDItemIsScreenCapture`), so a live metadata query reports each new
/// one. Reading the files needs access to the folder they are saved in (the Desktop by default),
/// which macOS asks for once.
///
/// A screenshot copied to the clipboard (⌃⇧⌘4, or the Screenshot app set to Clipboard) never becomes
/// a file, so the clipboard's change count is looked at once a second (types only), and the image
/// read when what's there is an image and nothing else, as a screenshot leaves it. An image copied
/// from an app carries its source or other types along and is left alone.
@MainActor
final class ScreenshotWatcher {
    static let enabledKey = "screenshots.addSystemScreenshots"

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var since = Date()
    private let onNew: ([URL]) -> Void
    private let onCopied: (Data) -> Void
    private let pasteboard = SystemPasteboard()
    private var clipboardTimer: Timer?
    private var lastChange = 0

    init(onNew: @escaping ([URL]) -> Void, onCopied: @escaping (Data) -> Void = { _ in }) {
        self.onNew = onNew
        self.onCopied = onCopied
    }

    /// What a screenshot copied to the clipboard leaves there: image types and nothing else.
    nonisolated static func isScreenshotCopy(types: [String]) -> Bool {
        let images: Set = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
        let aliases: Set = ["Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type"] // AppKit's legacy names for the same
        return types.contains(where: images.contains) && Set(types).isSubset(of: images.union(aliases))
    }

    /// Where macOS saves screenshots: the folder chosen in the Screenshot app, else the Desktop.
    static var folder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    var isRunning: Bool { query != nil }

    func start() {
        guard query == nil else { return }
        since = Date()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")
        query.searchScopes = [Self.folder]
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                // Plain values only across to the main actor; metadata items aren't Sendable.
                let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []).compactMap { item in
                    (item.value(forAttribute: NSMetadataItemPathKey) as? String).flatMap { path in
                        (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date).map { (path, $0) }
                    }
                }
                MainActor.assumeIsolated { self?.handle(added) }
            },
        ]
        query.start()
        self.query = query

        lastChange = pasteboard.changeCount // what's on the clipboard now was there before
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        timer.tolerance = 0.5 // let the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private func checkClipboard() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        // Clipboard history's excluded apps (password managers) are left out here too: a QR code copied
        // from one is an image and nothing else, just like a screenshot.
        let excluded = ClipboardPolicy.defaultExcludedApps + (UserDefaults.standard.stringArray(forKey: ClipboardKeys.excludedApps) ?? [])
        guard !excluded.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""),
              pasteboard.readPermission != .denied, Self.isScreenshotCopy(types: pasteboard.types),
              let data = pasteboard.imageData() else { return }
        onCopied(data)
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func handle(_ items: [(path: String, created: Date)]) {
        let urls = items.filter { Self.isNew(created: $0.created, since: since) }.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { onNew(urls) }
    }

    /// Only screenshots saved after the watcher started (a re-index reports old ones as added too).
    nonisolated static func isNew(created: Date, since: Date) -> Bool { created >= since.addingTimeInterval(-2) }
}
