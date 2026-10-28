// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// Adds screenshots taken with the system shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5) to the library as they are
/// saved. Off until the user turns it on; screenshots from before are left alone.
///
/// Spotlight tags them (`kMDItemIsScreenCapture`), so a live metadata query reports each new one;
/// no polling. Reading the files needs access to the folder they are saved in (the Desktop by
/// default), which macOS asks for once.
@MainActor
final class ScreenshotWatcher {
    static let enabledKey = "screenshots.addSystemScreenshots"

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var since = Date()
    private let onNew: ([URL]) -> Void

    init(onNew: @escaping ([URL]) -> Void) {
        self.onNew = onNew
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
    }

    func stop() {
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
