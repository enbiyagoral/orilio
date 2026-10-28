// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// An extension's `orilio-extension.json`: who it is, what it provides and every capability it asks
/// for. Validated strictly (`ManifestValidator`): unknown keys anywhere are refused.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var license: String
    public var minOrilio: String?
    public var provides: [Capability]
    public var refresh: Refresh?
    public var permissions: Permissions
    public var settings: [Setting]

    public enum Capability: String, Codable, Sendable, CaseIterable {
        case ear = "widget.ear"
        case island = "widget.island"
        case reminders
        case actions
    }

    public struct Refresh: Codable, Equatable, Sendable {
        public var everyMinutes: Int
    }

    public struct Permissions: Codable, Equatable, Sendable {
        /// Hosts the extension may reach (HTTPS only, exact host names).
        public var network: [String]
        public var notifications: Bool
        /// Only "city-picker": a city the user picks, never GPS.
        public var location: String?
        public var storage: Bool

        public init(network: [String] = [], notifications: Bool = false, location: String? = nil, storage: Bool = false) {
            self.network = network
            self.notifications = notifications
            self.location = location
            self.storage = storage
        }

        /// Anything left out is not asked for.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
            notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
            location = try c.decodeIfPresent(String.self, forKey: .location)
            storage = try c.decodeIfPresent(Bool.self, forKey: .storage) ?? false
        }

        /// Everything in `self` that `other` didn't already allow (an update asking for more).
        public func added(since other: Permissions) -> Permissions {
            Permissions(network: network.filter { !other.network.contains($0) },
                        notifications: notifications && !other.notifications,
                        location: location != nil && other.location == nil ? location : nil,
                        storage: storage && !other.storage)
        }

        public var isEmpty: Bool { network.isEmpty && !notifications && location == nil && !storage }
    }

    public struct Setting: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// A city the user picks (name, coordinates, time zone), resolved by Orilio.
            case city
            /// A segmented control (a few short options).
            case choice
            /// A pop-up menu (longer option names).
            case select
            case toggle
        }

        public struct Option: Codable, Equatable, Sendable {
            public var value: JSONValue
            public var label: String
        }

        public var key: String
        public var type: Kind
        public var label: String
        public var options: [Option]?
        public var `default`: JSONValue?
    }

    /// The minimum the host waits between refreshes.
    public static let minimumRefreshMinutes = 5
    public var refreshMinutes: Int { max(Self.minimumRefreshMinutes, refresh?.everyMinutes ?? 15) }
}

/// A JSON value of any kind, for settings and the values passed to and from scripts.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    /// How a setting's value reads in a label ("10", "true", "İstanbul").
    public var display: String {
        switch self {
        case .null: ""
        case .bool(let b): b ? "On" : "Off"
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .string(let s): s
        case .array, .object: ""
        }
    }
}

public enum ManifestError: Error, Equatable, LocalizedError {
    case notJSON
    case unknownKey(String)
    case missing(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON: "The manifest isn't valid JSON."
        case .unknownKey(let key): "The manifest has a key Orilio doesn't know: \(key)."
        case .missing(let key): "The manifest is missing \(key)."
        case .invalid(let what): "The manifest's \(what) isn't valid."
        }
    }
}

public enum ManifestValidator {
    static let topKeys: Set<String> = ["schema", "id", "name", "version", "author", "license", "minOrilio", "provides",
                                       "refresh", "permissions", "settings"]
    static let required: [String] = ["schema", "id", "name", "version", "author", "license", "provides", "permissions"]
    static let permissionKeys: Set<String> = ["network", "notifications", "location", "storage"]
    static let settingKeys: Set<String> = ["key", "type", "label", "options", "default"]

    /// Parses and checks a manifest. Anything unexpected is an error, never ignored.
    public static func validate(_ data: Data) throws -> ExtensionManifest {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ManifestError.notJSON }
        try only(topKeys, in: root, at: "")
        for key in required where root[key] == nil { throw ManifestError.missing(key) }
        if let permissions = root["permissions"] as? [String: Any] { try only(permissionKeys, in: permissions, at: "permissions.") }
        if let refresh = root["refresh"] as? [String: Any] { try only(["everyMinutes"], in: refresh, at: "refresh.") }
        for (index, setting) in ((root["settings"] as? [[String: Any]]) ?? []).enumerated() {
            try only(settingKeys, in: setting, at: "settings[\(index)].")
            for option in (setting["options"] as? [[String: Any]]) ?? [] { try only(["value", "label"], in: option, at: "settings[\(index)].options.") }
        }

        var object = root
        if object["settings"] == nil { object["settings"] = [] }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: normalized)
        } catch {
            throw ManifestError.invalid("structure")
        }

        guard manifest.schema == 1 else { throw ManifestError.invalid("schema") }
        guard manifest.id.range(of: #"^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$"#, options: .regularExpression) != nil,
              manifest.id.count <= 80 else { throw ManifestError.invalid("id") }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty, manifest.name.count <= 40 else { throw ManifestError.invalid("name") }
        guard manifest.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { throw ManifestError.invalid("version") }
        guard !manifest.provides.isEmpty, Set(manifest.provides).count == manifest.provides.count else { throw ManifestError.invalid("provides") }
        if let every = manifest.refresh?.everyMinutes, !(1...1_440).contains(every) { throw ManifestError.invalid("refresh") }
        for host in manifest.permissions.network where !isHostName(host) { throw ManifestError.invalid("network domain \(host)") }
        if let location = manifest.permissions.location, location != "city-picker" { throw ManifestError.invalid("location") }
        var keys = Set<String>()
        for setting in manifest.settings {
            guard keys.insert(setting.key).inserted, setting.key.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil
            else { throw ManifestError.invalid("setting \(setting.key)") }
            if setting.type == .choice || setting.type == .select, (setting.options ?? []).isEmpty { throw ManifestError.invalid("setting \(setting.key)") }
            if setting.type == .city, manifest.permissions.location != "city-picker" { throw ManifestError.invalid("setting \(setting.key)") }
        }
        return manifest
    }

    private static func only(_ allowed: Set<String>, in object: [String: Any], at path: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) { throw ManifestError.unknownKey(path + unknown) }
    }

    /// "api.aladhan.com": letters, digits and hyphens in dot-separated labels; no scheme, port, path or wildcard.
    public static func isHostName(_ host: String) -> Bool {
        host.count <= 253 && host.range(of: #"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) != nil
    }
}

/// Whether a URL may be fetched for an extension: HTTPS to exactly one of its declared hosts.
public enum DomainPolicy {
    public static func allows(_ url: URL, hosts: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return hosts.contains(host)
    }
}
