// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import CryptoKit
import Foundation
import Observation
import OrilioExtensionKit

/// One extension the catalog offers. The permissions mirror its manifest: an install whose manifest
/// asks for anything else is refused.
struct CatalogEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var tagline: String
    var description: String
    var author: String
    var version: String
    var license: String
    /// productivity, developer, lifestyle or finance.
    var category: String
    /// A name from `ExtensionIcons` and a tint from `ExtensionTint`.
    var icon: String?
    var tint: String?
    /// The "In the notch" bullets.
    var does: [String]
    var permissions: ExtensionManifest.Permissions
    /// A zip on GitHub Releases (HTTPS), or for an extension that ships inside Orilio, its folder name.
    var package: String
    /// The zip's SHA-256, hex. Required for a download.
    var sha256: String?
}

struct CatalogIndex: Codable, Equatable {
    var schema: Int
    var extensions: [CatalogEntry]

    static func decode(_ data: Data) throws -> CatalogIndex {
        let index = try JSONDecoder().decode(CatalogIndex.self, from: data)
        guard index.schema == 1 else { throw CatalogError.unsupported }
        return index
    }
}

enum CatalogError: LocalizedError, Equatable {
    case unsupported
    case checksum
    case notAPackage
    case mismatch(String)
    case download(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This catalog needs a newer Orilio."
        case .checksum: "The download doesn't match the catalog’s checksum, so it wasn't installed."
        case .notAPackage: "The download isn't an Orilio extension."
        case .mismatch(let what): String(localized: "The extension’s \(L(what)) doesn't match the catalog, so it wasn't installed.")
        case .download(let reason): String(localized: "The extension couldn't be downloaded: \(reason)")
        }
    }
}

/// The extensions on offer: the ones that ship inside Orilio, plus the community index once it exists.
@MainActor @Observable
final class ExtensionCatalog {
    static let shared = ExtensionCatalog()

    /// The community index. The only network call Orilio itself makes for extensions.
    /// ponytail: nil until the `enbiyagoral/orilio-extensions` repository exists; then
    /// `https://raw.githubusercontent.com/enbiyagoral/orilio-extensions/main/index.json`.
    static let indexURL: URL? = nil
    static let buildYourOwnURL = URL(string: "https://github.com/enbiyagoral/orilio/tree/main/extensions")!

    private(set) var entries: [CatalogEntry] = []
    /// Set when the community index can't be reached and nothing is cached.
    private(set) var offline = false

    @ObservationIgnored private let bundled: URL?
    @ObservationIgnored private let cache: URL
    @ObservationIgnored private let remote: URL?

    init(bundled: URL? = Bundle.main.resourceURL?.appending(path: "Extensions", directoryHint: .isDirectory),
         cache: URL = ExtensionStore.defaultRoot.deletingLastPathComponent().appending(path: "catalog.json"),
         remote: URL? = ExtensionCatalog.indexURL) {
        self.bundled = bundled
        self.cache = cache
        self.remote = remote
    }

    /// Reads the bundled and cached entries, then the community index when it is a day old (or `force`, on opening the window).
    func load(force: Bool = false) async {
        let shipped = bundled.flatMap { try? CatalogIndex.decode(Data(contentsOf: $0.appending(path: "catalog.json"))) }?.extensions ?? []
        let cached = (try? CatalogIndex.decode(Data(contentsOf: cache)))?.extensions
        entries = merge(shipped, cached ?? [])
        guard let remote else { return }
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
        guard force || age.map({ $0 > 86_400 }) ?? true else { return }
        do {
            let (data, _) = try await URLSession(configuration: .ephemeral).data(from: remote)
            let index = try CatalogIndex.decode(data)
            try? data.write(to: cache, options: .atomic)
            entries = merge(shipped, index.extensions)
            offline = false
        } catch {
            offline = cached == nil
        }
    }

    /// A shipped extension wins over a catalog copy of the same id.
    private func merge(_ shipped: [CatalogEntry], _ community: [CatalogEntry]) -> [CatalogEntry] {
        shipped + community.filter { entry in !shipped.contains { $0.id == entry.id } }
    }

    /// The package folder for an entry: the shipped copy, or the download checked and unpacked.
    func packageFolder(_ entry: CatalogEntry) async throws -> URL {
        if let bundled, !entry.package.hasPrefix("https://") {
            return bundled.appending(path: entry.package, directoryHint: .isDirectory)
        }
        guard let url = URL(string: entry.package), url.scheme == "https", let sha = entry.sha256 else { throw CatalogError.notAPackage }
        let data: Data
        do {
            let (bytes, response) = try await URLSession(configuration: .ephemeral).data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.download("the server said no") }
            data = bytes
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.download(error.localizedDescription)
        }
        return try Self.unpack(data, sha256: sha)
    }

    /// Checks the zip against its SHA-256 and unpacks it into a temporary folder.
    nonisolated static func unpack(_ zip: Data, sha256: String) throws -> URL {
        guard zip.count <= 5 * 1024 * 1024 else { throw CatalogError.notAPackage }
        let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw CatalogError.checksum }
        let work = FileManager.default.temporaryDirectory.appending(path: "orilio-extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appending(path: "package.zip")
        try zip.write(to: archive)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, work.appending(path: "out").path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CatalogError.notAPackage }
        // The manifest at the top, or in the one folder the zip holds.
        let out = work.appending(path: "out", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: out.appending(path: "orilio-extension.json").path) { return out }
        let inner = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let folder = inner.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "orilio-extension.json").path) })
        else { throw CatalogError.notAPackage }
        return folder
    }

    /// The package's manifest, checked against its entry: same id, version and permissions.
    nonisolated static func verify(_ folder: URL, against entry: CatalogEntry) throws -> ExtensionManifest {
        let manifest = try ExtensionPackage.read(folder)
        guard manifest.id == entry.id else { throw CatalogError.mismatch("id") }
        guard manifest.version == entry.version else { throw CatalogError.mismatch("version") }
        guard manifest.permissions.same(as: entry.permissions) else { throw CatalogError.mismatch("permissions") }
        return manifest
    }

    /// Downloads, checks and installs an entry with the permissions the user just allowed.
    func install(_ entry: CatalogEntry, host: ExtensionHost = .shared) async throws {
        let folder = try await packageFolder(entry)
        let manifest = try Self.verify(folder, against: entry)
        try host.install(from: folder, granted: manifest.permissions, local: false)
    }

    /// A newer version in the catalog than the one installed.
    static func hasUpdate(_ entry: CatalogEntry, installed: InstalledExtension?) -> Bool {
        guard let installed, !installed.state.local else { return false }
        return entry.version.compare(installed.manifest.version, options: .numeric) == .orderedDescending
    }
}

extension ExtensionManifest.Permissions {
    /// The same capabilities, whatever order the domains are listed in.
    func same(as other: Self) -> Bool {
        Set(network) == Set(other.network) && notifications == other.notifications && location == other.location && storage == other.storage
    }

    /// The "Can access" lines: what each permission is, and its detail.
    var lines: [(symbol: String, label: String, detail: String, mono: Bool)] {
        var lines: [(String, String, String, Bool)] = []
        if !network.isEmpty { lines.append(("globe", "Internet", String(localized: "\(network.joined(separator: ", ")) only"), true)) }
        if notifications { lines.append(("bell", "Notifications", "reminders you turn on", false)) }
        if location != nil { lines.append(("mappin.and.ellipse", "Location", "a city you pick — no GPS", false)) }
        if storage { lines.append(("shippingbox", "Own storage", "its settings and data, on this Mac", false)) }
        return lines
    }

    /// The card's chips: "1 domain" or "No internet", and "Notifications".
    var chips: [String] {
        [network.isEmpty ? "No internet" : network.count == 1 ? "1 domain" : "\(network.count) domains"] + (notifications ? ["Notifications"] : [])
    }
}
