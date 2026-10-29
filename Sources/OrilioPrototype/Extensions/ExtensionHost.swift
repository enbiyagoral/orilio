// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation
import OrilioExtensionKit
import UserNotifications

/// One installed extension: its package, the user's choices and what it last showed.
struct InstalledExtension: Identifiable, Equatable {
    var manifest: ExtensionManifest
    var state: ExtensionState
    var result: ExtensionResult?
    var diagnostics = Diagnostics()

    var id: String { manifest.id }

    struct Diagnostics: Equatable {
        var lastRun: Date?
        var lastError: String?
        var residentBytes: UInt64 = 0
        var notResponding = false
        var failures = 0
    }
}

/// What the user decided for an extension, saved by `ExtensionStore`.
struct ExtensionState: Codable, Equatable {
    /// "Show in the notch".
    var enabled = true
    var settings: [String: JSONValue] = [:]
    var storage: [String: JSONValue] = [:]
    /// What the user allowed at install (an update asking for more asks again).
    var granted = ExtensionManifest.Permissions()
    var installedAt = Date()
    /// Loaded from a folder in Developer Mode rather than the catalog.
    var local = false

    init() {}

    /// Every field may be missing (a field added later, an older file): it takes its default, so one
    /// new field never costs every extension its settings, storage and grants.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExtensionState()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        settings = try c.decodeIfPresent([String: JSONValue].self, forKey: .settings) ?? defaults.settings
        storage = try c.decodeIfPresent([String: JSONValue].self, forKey: .storage) ?? defaults.storage
        granted = try c.decodeIfPresent(ExtensionManifest.Permissions.self, forKey: .granted) ?? defaults.granted
        installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? defaults.installedAt
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? defaults.local
    }
}

/// The packages on disk: Application Support/Orilio/Extensions/<id>/ (manifest, script, icon) and one
/// state.json with every extension's settings, storage and grants.
struct ExtensionStore {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Orilio/Extensions", directoryHint: .isDirectory)
    }

    init(root: URL = ExtensionStore.defaultRoot) { self.root = root }

    func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    private var stateURL: URL { root.appending(path: "state.json") }

    /// A file that can't be read is put aside before anything is saved over it.
    func loadState() -> [String: ExtensionState] {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [:] }
        if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode([String: ExtensionState].self, from: data) {
            return state
        }
        let aside = root.appending(path: "state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: stateURL, to: aside)
        return [:]
    }

    func saveState(_ state: [String: ExtensionState]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// The installed packages whose manifest still validates; a broken one is skipped, not loaded.
    func packages() -> [(ExtensionManifest, String)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.compactMap { folder in
            guard let manifest = try? ExtensionPackage.read(folder),
                  let script = try? String(contentsOf: folder.appending(path: "main.js"), encoding: .utf8) else { return nil }
            return (manifest, script)
        }.sorted { $0.0.name < $1.0.name }
    }

    /// Copies a checked package folder in, replacing an older version of the same extension.
    func install(from source: URL, id: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = folder(id)
        let staging = root.appending(path: ".\(id).incoming", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in ExtensionPackage.files {
            let file = source.appending(path: name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.copyItem(at: file, to: staging.appending(path: name))
            }
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
    }
}

/// A package folder: `orilio-extension.json`, `main.js`, and optionally an icon, README and license.
/// Nothing else is copied or read.
enum ExtensionPackage {
    static let files = ["orilio-extension.json", "main.js", "icon.svg", "README.md", "LICENSE"]
    static let maxScriptBytes = 512 * 1024

    static func read(_ folder: URL) throws -> ExtensionManifest {
        // Plain files only: a link named main.js could hand the extension any file on the Mac.
        for name in files {
            let path = folder.appending(path: name).path
            guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType else { continue }
            guard type == .typeRegular else { throw ManifestError.invalid("\(name) (not a plain file)") }
        }
        let manifest = try ManifestValidator.validate(try Data(contentsOf: folder.appending(path: "orilio-extension.json")))
        let script = folder.appending(path: "main.js")
        guard let size = try? script.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxScriptBytes else {
            throw ManifestError.invalid("script (missing, or over \(maxScriptBytes / 1024) KB)")
        }
        return manifest
    }
}

/// Runs extensions: keeps the sandboxed runner going, calls each enabled extension on its schedule,
/// brokers its fetches, schedules its reminders, and holds what it last returned for the island.
@MainActor @Observable
final class ExtensionHost {
    static let shared = ExtensionHost()

    private(set) var installed: [InstalledExtension] = []
    /// Settings › Extensions › Developer Mode: load a local folder.
    var developerMode: Bool {
        get { access(keyPath: \.installed); return UserDefaults.standard.bool(forKey: "extensions.developerMode") }
        set { UserDefaults.standard.set(newValue, forKey: "extensions.developerMode"); installed = installed }
    }

    @ObservationIgnored let store: ExtensionStore
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private lazy var broker = FetchBroker { [weak self] id in await self?.grantedHosts(id) ?? [] }
    /// The runner's connection: the XPC service, or an in-process listener in tests.
    @ObservationIgnored private let makeConnection: @MainActor () -> NSXPCConnection
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadedScripts = Set<String>()
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Off in tests: nothing is started and no notifications are touched.
    @ObservationIgnored private let startsRunner: Bool

    init(store: ExtensionStore = ExtensionStore(), startsRunner: Bool = true,
         connection: @escaping @MainActor () -> NSXPCConnection = { NSXPCConnection(serviceName: ExtensionXPC.serviceName) }) {
        self.store = store
        self.startsRunner = startsRunner
        makeConnection = connection
    }

    /// Loads what's installed and starts the enabled extensions. Once, at launch.
    func start() {
        reload()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ExtensionHost.shared.refreshAll() }
        }
        refreshAll()
    }

    func reload() {
        let states = store.loadState()
        installed = store.packages().map { manifest, _ in
            let previous = installed.first { $0.id == manifest.id }
            return InstalledExtension(manifest: manifest, state: states[manifest.id] ?? ExtensionState(), result: previous?.result,
                                      diagnostics: previous?.diagnostics ?? .init())
        }
        loadedScripts.removeAll()
    }

    // MARK: What the island shows

    /// The extension the island's Extensions tab shows, and the one that may claim the ears.
    var active: [InstalledExtension] { installed.filter { $0.state.enabled && $0.result != nil } }
    var hasIslandContent: Bool { active.contains { $0.result?.island != nil } }

    /// The ear an extension asks for: the first enabled one that has one. Always below meetings, focus and confirmations.
    var ear: ExtensionEarContent? {
        _ = dueTick // re-read when an ear's moment to share the notch with music comes
        guard let ext = installed.first(where: { $0.state.enabled && $0.result?.ear != nil }), let ear = ext.result?.ear else { return nil }
        let target = [ear.trailing, ear.leading].compactMap { $0?.style == "countdown" ? $0?.target : nil }.first
        return ExtensionEarContent(extensionID: ext.id, leading: ear.leading, trailing: ear.trailing,
                                   dueFrom: ExtensionEarContent.dueFrom(target: target, reminders: ext.result?.reminders ?? []))
    }

    /// Bumped when an ear becomes due (see `ExtensionEarContent.dueFrom`), so the notch re-resolves then.
    private(set) var dueTick = 0
    @ObservationIgnored private var dueTask: Task<Void, Never>?

    /// One wakeup at the moment the current ear becomes due; nothing polls.
    private func scheduleDue() {
        dueTask?.cancel()
        guard let due = ear?.dueFrom, due > Date() else { return }
        dueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.dueTick += 1
        }
    }

    // MARK: Lifecycle of one extension

    func setEnabled(_ id: String, _ on: Bool) {
        update(id) { $0.state.enabled = on }
        if on { refresh(id) } else { clear(id) }
    }

    func setSetting(_ id: String, key: String, value: JSONValue) {
        update(id) { $0.state.settings[key] = value }
        call(id, function: "onSettingsChanged")
    }

    /// The value a setting has now: chosen, else the manifest's default.
    func setting(_ ext: InstalledExtension, _ setting: ExtensionManifest.Setting) -> JSONValue? {
        ext.state.settings[setting.key] ?? setting.default
    }

    /// Installs a checked package folder with the permissions the user just allowed.
    func install(from folder: URL, granted: ExtensionManifest.Permissions, local: Bool) throws {
        let source = try ExtensionPackage.read(folder)
        try store.install(from: folder, id: source.id)
        // The copy is what runs: it must still ask for exactly what the user allowed, even if the
        // folder changed after the consent dialog read it.
        guard let manifest = try? ExtensionPackage.read(store.folder(source.id)), manifest.id == source.id,
              manifest.permissions.same(as: granted) else {
            store.remove(source.id)
            loadedScripts.remove(source.id)
            reload()
            throw ManifestError.invalid("permissions (the package changed during install)")
        }
        var states = store.loadState()
        var state = states[manifest.id] ?? ExtensionState()
        state.granted = granted
        state.local = local
        states[manifest.id] = state
        store.saveState(states)
        loadedScripts.remove(manifest.id)
        reload()
        refresh(manifest.id)
    }

    /// Removes the package, its storage and settings, and its scheduled reminders.
    func uninstall(_ id: String) {
        clear(id)
        connectionProxy()?.unload(extensionID: id)
        store.remove(id)
        var states = store.loadState()
        states[id] = nil
        store.saveState(states)
        reload()
    }

    func performAction(_ id: String, action: String) { call(id, function: "onAction", action: action) }

    func refreshAll() {
        for ext in installed where ext.state.enabled { refresh(ext.id) }
    }

    func refresh(_ id: String) { call(id, function: "refresh") }

    private func clear(_ id: String) {
        timers[id]?.cancel()
        timers[id] = nil
        update(id) { $0.result = nil }
        if startsRunner { Task { await ReminderPoster.replace(id, with: []) } } // tests have no notification center
    }

    // MARK: Calls

    private func call(_ id: String, function: String, action: String? = nil) {
        guard startsRunner, let ext = installed.first(where: { $0.id == id }), ext.state.enabled else { return }
        Task { @MainActor in
            do {
                try await ensureLoaded(ext)
                let context = CallContext(settings: settingValues(ext), storage: ext.state.storage, now: Date(),
                                          locale: Locale.preferredLanguages.first ?? "en", timeZone: TimeZone.current.identifier, action: action)
                let reply = try await withTimeout { try await self.send(id, function: function, context: context) }
                let result = try ExtensionResult.decode(reply.result).limited()
                if reply.residentBytes > ExtensionLimits.memoryBudgetBytes { restartRunner() } // the answer is in; start fresh
                // Uninstalled or turned off while it ran: its answer is no longer wanted.
                guard let ext = installed.first(where: { $0.id == id }), ext.state.enabled else { return }
                update(id) {
                    $0.result = result
                    if $0.manifest.permissions.storage { $0.state.storage = reply.storage }
                    $0.diagnostics = .init(lastRun: Date(), lastError: nil, residentBytes: reply.residentBytes)
                }
                saveStates()
                if ext.manifest.provides.contains(.reminders), ext.state.granted.notifications {
                    await ReminderPoster.replace(id, with: result.reminders ?? [], extensionName: ext.manifest.name)
                    // Gone while they were being set: take them back.
                    if !installed.contains(where: { $0.id == id && $0.state.enabled }) { await ReminderPoster.replace(id, with: []) }
                }
                schedule(id, refreshAt: result.refreshAt)
                scheduleDue()
            } catch {
                failed(id, error)
            }
        }
    }

    private func settingValues(_ ext: InstalledExtension) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for setting in ext.manifest.settings { if let value = self.setting(ext, setting) { values[setting.key] = value } }
        return values
    }

    /// The next refresh: on the manifest's schedule, or when the result goes stale, whichever is first.
    private func schedule(_ id: String, refreshAt: Date?) {
        guard let ext = installed.first(where: { $0.id == id }) else { return }
        timers[id]?.cancel()
        let regular = Date().addingTimeInterval(TimeInterval(ext.manifest.refreshMinutes * 60))
        let next = max(Date().addingTimeInterval(30), min(regular, refreshAt ?? regular))
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.refresh(id)
        }
    }

    private func failed(_ id: String, _ error: Error) {
        let timedOut = error is CallTimeout
        if timedOut { restartRunner() }
        update(id) {
            $0.diagnostics.lastError = timedOut ? "Not responding" : error.localizedDescription
            $0.diagnostics.notResponding = timedOut
            $0.diagnostics.failures += 1
        }
        // Back off: 1, 2, 4 … up to 60 minutes after repeated failures.
        guard let ext = installed.first(where: { $0.id == id }) else { return }
        let minutes = min(60, 1 << min(6, ext.diagnostics.failures - 1))
        schedule(id, refreshAt: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func update(_ id: String, _ change: (inout InstalledExtension) -> Void) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        change(&installed[index])
    }

    private func saveStates() {
        var states = store.loadState()
        for ext in installed { states[ext.id] = ext.state }
        store.saveState(states)
    }

    // MARK: The runner

    private func connectionProxy() -> ExtensionRunnerProtocol? {
        if connection == nil {
            let connection = makeConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: ExtensionRunnerProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: ExtensionHostProtocol.self)
            connection.exportedObject = broker
            // A late handler of an earlier connection must not drop the current one.
            let tag = ObjectIdentifier(connection)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.runnerWentAway(tag) }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.runnerWentAway(tag) }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxy as? ExtensionRunnerProtocol
    }

    /// A proxy whose call ends with `onError` when the runner dies or the connection drops, so a
    /// waiting call is never left without an answer.
    private func runnerProxy(onError: @escaping @Sendable (String) -> Void) -> ExtensionRunnerProtocol? {
        guard connectionProxy() != nil else { return nil }
        return connection?.remoteObjectProxyWithErrorHandler { onError($0.localizedDescription) } as? ExtensionRunnerProtocol
    }

    /// Hosts a fetch may go to: declared in the manifest AND allowed by the user.
    func grantedHosts(_ id: String) -> [String] {
        guard let ext = installed.first(where: { $0.id == id }) else { return [] }
        return ext.manifest.permissions.network.filter(ext.state.granted.network.contains)
    }

    private func runnerWentAway(_ tag: ObjectIdentifier? = nil) {
        if let tag, connection.map(ObjectIdentifier.init) != tag { return }
        connection = nil
        loadedScripts.removeAll() // a new process starts empty
    }

    private func restartRunner() {
        // Never this process (an in-process runner in tests).
        if let pid = connection?.processIdentifier, pid > 0, pid != getpid() { kill(pid, SIGKILL) }
        connection?.invalidate()
        runnerWentAway()
    }

    private func ensureLoaded(_ ext: InstalledExtension) async throws {
        guard !loadedScripts.contains(ext.id) else { return }
        let script = try String(contentsOf: store.folder(ext.id).appending(path: "main.js"), encoding: .utf8)
        let manifest = try Data(contentsOf: store.folder(ext.id).appending(path: "orilio-extension.json"))
        let id = ext.id
        let error: String? = try await withTimeout { @MainActor in
            await withCheckedContinuation { continuation in
                let done = ResumeOnce<String?> { continuation.resume(returning: $0) }
                guard let proxy = self.runnerProxy(onError: { done($0) }) else { return done("The extension runner isn't available") }
                proxy.load(extensionID: id, script: script, manifest: manifest) { done($0) }
            }
        }
        if let error { throw CallError(error) }
        loadedScripts.insert(ext.id)
    }

    private func send(_ id: String, function: String, context: CallContext) async throws -> CallReply {
        let data = try JSONEncoder().encode(context)
        let (reply, error): (Data?, String?) = await withCheckedContinuation { continuation in
            let done = ResumeOnce<(Data?, String?)> { continuation.resume(returning: $0) }
            guard let proxy = runnerProxy(onError: { done((nil, $0)) }) else { return done((nil, "The extension runner isn't available")) }
            proxy.call(extensionID: id, function: function, context: data) { done(($0, $1)) }
        }
        if let error { throw CallError(error) }
        guard let reply, let decoded = try? JSONDecoder().decode(CallReply.self, from: reply) else { throw CallError("No answer") }
        return decoded
    }
}

/// NSXPCConnection proxies may be used from any thread.
struct XPCProxy: @unchecked Sendable {
    let runner: ExtensionRunnerProtocol
}

struct CallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CallTimeout: Error {}

/// Runs `work`, giving up after `ExtensionLimits.callTimeout` whether or not `work` ever finishes.
/// A race, not a task group: a group waits for all its children, and work parked on an XPC reply
/// that never comes (a runner stuck in a loop) would keep the timeout from ever returning.
func withTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let finish = ResumeOnce<Result<T, Error>> { continuation.resume(with: $0) }
        let worker = Task {
            do { finish(.success(try await work())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: ExtensionLimits.callTimeout)
            worker.cancel()
            finish(.failure(CallTimeout()))
        }
    }
}

/// Hands a value on once and drops the rest: an XPC call ends with its reply or its connection's
/// error, and a timeout may get there first. `NSLock` makes the one hand-off race-free across threads.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: ((T) -> Void)?

    init(_ deliver: @escaping (T) -> Void) { self.deliver = deliver }

    func callAsFunction(_ value: T) {
        let once = lock.withLock { () -> ((T) -> Void)? in
            defer { deliver = nil }
            return deliver
        }
        once?(value)
    }
}

/// What an extension's ear shows (see `LiveActivityResolver`).
struct ExtensionEarContent: Equatable {
    let extensionID: String
    let leading: ExtensionResult.EarPart?
    let trailing: ExtensionResult.EarPart?
    /// From when it shares the notch with music; until then music keeps both ears.
    var dueFrom: Date? = nil

    /// The earliest reminder for the countdown's moment (a reminder 10 or 15 min before), and never
    /// later than 10 minutes before it.
    static func dueFrom(target: Date?, reminders: [ExtensionResult.Reminder]) -> Date? {
        guard let target else { return nil }
        let earliest = reminders.map(\.date).filter { $0 <= target && $0 > target.addingTimeInterval(-3_600) }.min() ?? target
        return min(earliest, target.addingTimeInterval(-600))
    }

    func isDue(at now: Date) -> Bool { dueFrom.map { now >= $0 } ?? true }
}

// MARK: - Fetches

/// The app side of `orilio.fetch`: HTTPS to the extension's declared and allowed hosts only, redirects
/// included, with size, time and in-flight limits. No cookies or cache are shared with anything else.
/// Unchecked-Sendable: `permissions` is set once at init and `inFlight` is only touched under `lock`.
final class FetchBroker: NSObject, ExtensionHostProtocol, @unchecked Sendable {
    /// The hosts an extension may reach (asked on the main actor). Set once: fetches read it on any thread.
    let permissions: @Sendable (String) async -> [String]
    /// Guards `inFlight`, which fetch tasks on any thread change.
    private let lock = NSLock()
    private var inFlight: [String: Int] = [:]

    init(permissions: @escaping @Sendable (String) async -> [String]) {
        self.permissions = permissions
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ExtensionLimits.fetchTimeout
        configuration.timeoutIntervalForResource = ExtensionLimits.fetchTimeout // a slow trickle ends too
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Orilio-Extension"]
        return URLSession(configuration: configuration)
    }()

    func fetch(extensionID: String, url: String, method: String, body: Data?, reply: @escaping @Sendable (Data?, Int, String?) -> Void) {
        let admitted = lock.withLock {
            guard inFlight[extensionID, default: 0] < ExtensionLimits.fetchesInFlight else { return false }
            inFlight[extensionID, default: 0] += 1
            return true
        }
        guard admitted else { return reply(nil, 0, "Too many fetches at once") }
        Task {
            defer { lock.withLock { inFlight[extensionID, default: 1] -= 1 } }
            let hosts = await permissions(extensionID)
            guard let target = URL(string: url), DomainPolicy.allows(target, hosts: hosts) else {
                return reply(nil, 0, "Blocked: \(URL(string: url)?.host ?? url) isn't one of this extension's domains")
            }
            guard ["GET", "POST"].contains(method.uppercased()) else { return reply(nil, 0, "Only GET and POST are allowed") }
            var request = URLRequest(url: target)
            request.httpMethod = method.uppercased()
            request.httpBody = body
            do {
                let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard(hosts: hosts))
                // Counted as it arrives: past the limit, the download stops rather than filling memory.
                var data = Data()
                for try await byte in bytes {
                    guard data.count < ExtensionLimits.fetchBytes else { return reply(nil, 0, "The response is too large") }
                    data.append(byte)
                }
                reply(data, (response as? HTTPURLResponse)?.statusCode ?? 0, nil)
            } catch {
                reply(nil, 0, error.localizedDescription)
            }
        }
    }
}

/// A redirect to a host the extension didn't declare is refused.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let hosts: [String]
    init(hosts: [String]) { self.hosts = hosts }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url.map { DomainPolicy.allows($0, hosts: hosts) } == true ? request : nil
    }
}

// MARK: - Reminders

/// Schedules an extension's reminders under Orilio's identity, replacing its previous set each time.
@MainActor
enum ReminderPoster {
    static func prefix(_ id: String) -> String { "ext.\(id)." }
    /// When each extension's reminders were set to go off, so results in a row can't add up past the hourly cap.
    private static var scheduled: [String: [Date]] = [:]

    static func replace(_ id: String, with reminders: [ExtensionResult.Reminder], extensionName: String = "") async {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix(id)) }
        // One about to go off that the extension still wants stays: set again, it would fall inside the lead time.
        let wanted = Set(reminders.map { prefix(id) + $0.id })
        let kept = pending.filter {
            wanted.contains($0.identifier)
                && ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate().map { $0 < now.addingTimeInterval(ExtensionLimits.reminderLead) } == true
        }
        let keptIDs = Set(kept.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !keptIDs.contains($0) })
        // What went off in the last hour, and what stays, count against the cap.
        let earlier = (scheduled[id] ?? []).filter { $0 <= now && $0 > now.addingTimeInterval(-3_600) }
            + kept.compactMap { ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }
        scheduled[id] = earlier
        guard !reminders.isEmpty, await center.notificationSettings().authorizationStatus == .authorized else { return }
        let plan = ReminderPlan.upcoming(reminders.filter { !keptIDs.contains(prefix(id) + $0.id) }, now: now, earlier: earlier)
        scheduled[id, default: []] += plan.map(\.date)
        for reminder in plan {
            let content = UNMutableNotificationContent()
            content.title = L(extensionName)
            content.body = [reminder.title, reminder.body].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix(id) + reminder.id, content: content, trigger: trigger))
        }
    }
}

/// Which reminders to schedule. Pure.
enum ReminderPlan {
    /// At least the lead time ahead, soonest first, unique by id, no more than the hourly cap in any
    /// hour (counting `earlier` ones), within the limit.
    static func upcoming(_ reminders: [ExtensionResult.Reminder], now: Date, earlier: [Date] = []) -> [ExtensionResult.Reminder] {
        var seen = Set<String>()
        var times = earlier
        var plan: [ExtensionResult.Reminder] = []
        for reminder in reminders.sorted(by: { $0.date < $1.date })
        where reminder.date >= now.addingTimeInterval(ExtensionLimits.reminderLead) && seen.insert(reminder.id).inserted {
            let hour = reminder.date.addingTimeInterval(-3_600)
            guard times.filter({ $0 > hour && $0 <= reminder.date }).count < ExtensionLimits.remindersPerHour else { continue }
            times.append(reminder.date)
            plan.append(reminder)
            if plan.count == ExtensionLimits.reminders { break }
        }
        return plan
    }
}
