import AppKit
import Observation

/// The clipboard history on disk:
///
///     Application Support/Orilio/Clipboard/
///         history.json   entries, written atomically
///         Images/        copied images, <id>.png
///
/// A history is a few hundred entries at most, so one JSON file is enough.
actor ClipboardStore {
    private struct File: Codable {
        var version = 1
        var items: [ClipItem]
    }

    let directory: URL
    var imageDirectory: URL { directory.appending(path: "Images", directoryHint: .isDirectory) }

    init(directory: URL = ClipboardStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Orilio/Clipboard", directoryHint: .isDirectory)
    }

    nonisolated func imageURL(_ name: String) -> URL { directory.appending(path: "Images/\(name)") }

    /// A missing or corrupt file loads as an empty history; entries naming a file that isn't
    /// their own managed image are dropped.
    func load() -> [ClipItem] {
        guard let data = try? Data(contentsOf: directory.appending(path: "history.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.items.filter { item in
            item.imageFileName.map { ClipboardPolicy.isManagedImageName($0, id: item.id) } ?? (item.kind != .image)
        }
    }

    func save(_ items: [ClipItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(File(items: items)).write(to: directory.appending(path: "history.json"), options: .atomic)
    }

    func writeImage(_ data: Data, for id: UUID) throws -> String {
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let name = "\(id.uuidString).png"
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        try png.write(to: imageURL(name), options: .atomic)
        return name
    }

    func image(_ name: String) -> Data? { try? Data(contentsOf: imageURL(name)) }

    func deleteImages(_ names: [String]) {
        for name in names where !name.contains("/") { try? FileManager.default.removeItem(at: imageURL(name)) }
    }

    /// Removes everything Orilio stored for the clipboard.
    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum ClipboardKeys {
    static let enabled = "clipboard.enabled"
    static let paused = "clipboard.paused"
    static let maxItems = "clipboard.maxItems"
    static let retentionDays = "clipboard.retentionDays" // 0 = keep until removed
    static let excludedApps = "clipboard.excludedApps"
}

/// Clipboard history. Off until the user turns it on; nothing from before is imported.
///
/// macOS has no clipboard-change notification, so while history is on, Orilio checks the
/// pasteboard's change counter once a second. Reading the counter reads no content and shows no
/// alert; content is read only when the counter moved.
@MainActor @Observable
final class ClipboardModule {
    enum Status: Equatable {
        case off, on, paused
        /// macOS was told never to let Orilio read other apps' clipboard.
        case blocked
    }

    private(set) var items: [ClipItem] = []
    private(set) var status: Status = .off
    /// macOS 15.4+: "Ask" means the system may show an alert on each copy.
    private(set) var readPermission: ClipboardReadPermission = .allowed
    private(set) var copiedID: UUID?
    var query = ""

    @ObservationIgnored private let store: ClipboardStore
    @ObservationIgnored private let pasteboard: any PasteboardAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let frontmostApp: @MainActor () -> (id: String?, name: String?)
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored private var lastChange: Int
    @ObservationIgnored private var ownWrite: Int?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    static let checkInterval: TimeInterval = 1

    init(store: ClipboardStore = ClipboardStore(), pasteboard: (any PasteboardAccess)? = nil, defaults: UserDefaults = .standard,
         frontmostApp: @escaping @MainActor () -> (id: String?, name: String?) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.bundleIdentifier, app?.localizedName)
         },
         now: @escaping @MainActor () -> Date = Date.init) {
        self.store = store
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.defaults = defaults
        self.frontmostApp = frontmostApp
        self.now = now
        lastChange = self.pasteboard.changeCount
    }

    var isEnabled: Bool { defaults.bool(forKey: ClipboardKeys.enabled) }
    var maxItems: Int { (defaults.object(forKey: ClipboardKeys.maxItems) as? Int).map { max(10, $0) } ?? 200 }
    var retentionDays: Int { defaults.object(forKey: ClipboardKeys.retentionDays) as? Int ?? 7 }
    var excludedApps: [String] { defaults.stringArray(forKey: ClipboardKeys.excludedApps) ?? ClipboardPolicy.defaultExcludedApps }

    /// Shown in the panel: pinned first, then newest, filtered by the search text.
    var visibleItems: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = q.isEmpty ? items : items.filter { $0.preview.lowercased().contains(q) || ($0.sourceApp?.lowercased().contains(q) ?? false) }
        return matching.sorted { ($0.pinned ? 1 : 0, $0.copiedAt) > ($1.pinned ? 1 : 0, $1.copiedAt) }
    }

    // MARK: Lifecycle

    func start() async {
        guard isEnabled else { status = .off; return }
        items = await store.load()
        prune()
        resume()
    }

    /// Turning history on starts from now: whatever is on the clipboard already is not recorded.
    func enable() async {
        defaults.set(true, forKey: ClipboardKeys.enabled)
        defaults.set(false, forKey: ClipboardKeys.paused)
        items = await store.load()
        lastChange = pasteboard.changeCount
        resume()
    }

    /// Turning history off stops monitoring and deletes the stored history.
    func disable() async {
        defaults.set(false, forKey: ClipboardKeys.enabled)
        stopTimer()
        items = []
        status = .off
        await store.deleteAll()
    }

    func pause() {
        defaults.set(true, forKey: ClipboardKeys.paused)
        stopTimer()
        status = .paused
    }

    func resume() {
        guard isEnabled else { return }
        defaults.set(false, forKey: ClipboardKeys.paused)
        lastChange = pasteboard.changeCount // anything copied while paused stays unrecorded
        updatePermission()
        guard status != .blocked else { return }
        status = .on
        startTimer()
    }

    private func updatePermission() {
        readPermission = pasteboard.readPermission
        if readPermission == .denied {
            stopTimer()
            status = .blocked
        }
    }

    // MARK: Watching

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.5 // let the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// One check: compare the counter, and only if it moved, read and classify the content.
    func check() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if change == ownWrite { return } // Orilio's own copy-back
        updatePermission()
        guard status == .on else { return }
        let app = frontmostApp()
        if let id = app.id, excludedApps.contains(id) { return }
        guard let content = read() else { return }
        record(content, from: app.name)
    }

    private func read() -> ClipContent? {
        let types = pasteboard.types
        guard !types.isEmpty, !ClipboardPolicy.isPrivate(types: types) else { return nil }
        let files = pasteboard.fileURLs()
        if !files.isEmpty { return .files(files) }
        if types.contains("public.png") || types.contains("public.tiff"), let data = pasteboard.imageData() {
            return data.count <= ClipboardPolicy.maxImageBytes ? .image(data) : nil
        }
        guard let text = pasteboard.string(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounded = String(text.prefix(ClipboardPolicy.maxTextLength))
        return .text(bounded, ClipboardPolicy.kind(of: bounded))
    }

    func record(_ content: ClipContent, from app: String?) {
        let hash = content.hash
        let time = now()
        // Copying the same thing again moves it to the top instead of adding a duplicate.
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            items[index].copiedAt = time
            items[index].sourceApp = app ?? items[index].sourceApp
            scheduleSave()
            return
        }
        let id = UUID()
        switch content {
        case .text(let text, let kind):
            items.append(ClipItem(id: id, kind: kind, text: text, imageFileName: nil, imageSize: nil,
                                  copiedAt: time, sourceApp: app, pinned: false, contentHash: hash))
        case .files(let urls):
            items.append(ClipItem(id: id, kind: .files, text: urls.map(\.path).joined(separator: "\n"), imageFileName: nil,
                                  imageSize: nil, copiedAt: time, sourceApp: app, pinned: false, contentHash: hash))
        case .image(let data):
            let size = NSImage(data: data)?.size
            Task {
                guard let name = try? await store.writeImage(data, for: id) else { return }
                items.append(ClipItem(id: id, kind: .image, text: nil, imageFileName: name, imageSize: size,
                                      copiedAt: time, sourceApp: app, pinned: false, contentHash: hash))
                prune()
                scheduleSave()
            }
            return
        }
        prune()
        scheduleSave()
    }

    // MARK: Actions

    /// Puts an entry back on the clipboard. It isn't recorded again.
    func copy(_ item: ClipItem) async {
        var image: Data?
        if let name = item.imageFileName { image = await store.image(name) }
        ownWrite = pasteboard.write(item, image: image)
        lastChange = ownWrite ?? lastChange
        copiedID = item.id
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].copiedAt = now() }
        scheduleSave()
        try? await Task.sleep(for: .seconds(1.5))
        if copiedID == item.id { copiedID = nil }
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        scheduleSave()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        let images = [item.imageFileName].compactMap { $0 }
        Task { await store.deleteImages(images) }
        scheduleSave()
    }

    /// Removes everything except pinned entries.
    func clear() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        let images = removed.compactMap(\.imageFileName)
        Task { await store.deleteImages(images) }
        scheduleSave()
    }

    func imageURL(for item: ClipItem) -> URL? { item.imageFileName.map(store.imageURL) }

    /// Sends a copied image to the screenshot library, only when the user asks.
    func sendToLibrary(_ item: ClipItem, library: ScreenshotLibrary) async {
        guard item.kind == .image, let name = item.imageFileName, let data = await store.image(name) else { return }
        library.importData(data, source: .paste)
    }

    func setRetention(days: Int) { defaults.set(days, forKey: ClipboardKeys.retentionDays); prune(); scheduleSave() }
    func setMaxItems(_ count: Int) { defaults.set(count, forKey: ClipboardKeys.maxItems); prune(); scheduleSave() }

    /// ⌘1 … ⌘9 copy the nth visible entry.
    func handleKey(keyCode: UInt16, command: Bool) -> Bool {
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        guard command, let n = digits[keyCode], visibleItems.indices.contains(n - 1) else { return false }
        let item = visibleItems[n - 1]
        Task { await copy(item) }
        return true
    }

    private func prune() {
        let days = retentionDays
        let before = Set(items.compactMap(\.imageFileName))
        items = ClipboardPolicy.prune(items, maxItems: maxItems, maxAge: days > 0 ? Double(days) * 86_400 : nil, now: now())
        let gone = before.subtracting(items.compactMap(\.imageFileName))
        if !gone.isEmpty { Task { await store.deleteImages(Array(gone)) } }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            try? await self.store.save(self.items)
        }
    }

    func saveNow() async {
        pendingSave?.cancel()
        guard isEnabled else { return }
        try? await store.save(items)
    }

    static let pasteSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
}
