// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// What an extension's `refresh`, `onAction` or `onSettingsChanged` returns: data only. Orilio draws
/// it with its own components; countdowns are drawn from `target` dates, never by calling the script.
public struct ExtensionResult: Codable, Equatable, Sendable {
    public var ear: Ear?
    public var island: Island?
    public var actions: [Action]?
    public var reminders: [Reminder]?
    public var liveActivity: LiveActivity?
    /// When the result goes stale (a prayer time passes): the host refreshes then, as well as on its schedule.
    public var refreshAt: Date?

    public init(ear: Ear? = nil, island: Island? = nil, actions: [Action]? = nil, reminders: [Reminder]? = nil,
                liveActivity: LiveActivity? = nil, refreshAt: Date? = nil) {
        self.ear = ear
        self.island = island
        self.actions = actions
        self.reminders = reminders
        self.liveActivity = liveActivity
        self.refreshAt = refreshAt
    }

    public struct Ear: Codable, Equatable, Sendable {
        public var leading: EarPart?
        public var trailing: EarPart?
    }

    public struct EarPart: Codable, Equatable, Sendable {
        /// A name from Orilio's icon set (`ExtensionIcons`); anything else is left out.
        public var icon: String?
        public var text: String?
        /// A palette name or color; clamped to the theme (`ExtensionTint`).
        public var tint: String?
        /// "countdown": `text` is ignored and Orilio counts down to `target`.
        public var style: String?
        public var target: Date?
    }

    public struct Island: Codable, Equatable, Sendable {
        public var sections: [Section]
    }

    public enum Section: Codable, Equatable, Sendable {
        case hero(Hero)
        case list([Row])
        case footnote(String)
        case notice(Notice)

        public struct Hero: Codable, Equatable, Sendable {
            public var label: String?
            public var title: String
            public var countdownTo: Date?
            public var caption: String?
        }

        public struct Row: Codable, Equatable, Sendable {
            public enum State: String, Codable, Sendable { case past, next, later }
            public var title: String
            public var value: String
            public var state: State?
        }

        /// An empty or error state ("Choose a city"), drawn as Orilio's status card.
        public struct Notice: Codable, Equatable, Sendable {
            public var icon: String?
            public var title: String
            public var detail: String?
        }

        private enum Keys: String, CodingKey { case type, label, title, countdownTo, caption, rows, text, icon, detail }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "hero":
                self = .hero(Hero(label: try c.decodeIfPresent(String.self, forKey: .label), title: try c.decode(String.self, forKey: .title),
                                  countdownTo: try c.decodeIfPresent(Date.self, forKey: .countdownTo),
                                  caption: try c.decodeIfPresent(String.self, forKey: .caption)))
            case "list": self = .list(try c.decode([Row].self, forKey: .rows))
            case "footnote": self = .footnote(try c.decode(String.self, forKey: .text))
            case "notice":
                self = .notice(Notice(icon: try c.decodeIfPresent(String.self, forKey: .icon), title: try c.decode(String.self, forKey: .title),
                                      detail: try c.decodeIfPresent(String.self, forKey: .detail)))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown section \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .hero(let h):
                try c.encode("hero", forKey: .type)
                try c.encodeIfPresent(h.label, forKey: .label)
                try c.encode(h.title, forKey: .title)
                try c.encodeIfPresent(h.countdownTo, forKey: .countdownTo)
                try c.encodeIfPresent(h.caption, forKey: .caption)
            case .list(let rows):
                try c.encode("list", forKey: .type)
                try c.encode(rows, forKey: .rows)
            case .footnote(let text):
                try c.encode("footnote", forKey: .type)
                try c.encode(text, forKey: .text)
            case .notice(let n):
                try c.encode("notice", forKey: .type)
                try c.encodeIfPresent(n.icon, forKey: .icon)
                try c.encode(n.title, forKey: .title)
                try c.encodeIfPresent(n.detail, forKey: .detail)
            }
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
    }

    public struct Reminder: Codable, Equatable, Sendable {
        public var id: String
        public var date: Date
        public var title: String
        public var body: String?
    }

    public struct LiveActivity: Codable, Equatable, Sendable {
        public var until: Date?
        public var priority: String?
    }

    // MARK: Decoding

    /// Dates are ISO 8601, with or without fractional seconds (`Date.toISOString()` adds them).
    public static func decode(_ data: Data) throws -> ExtensionResult {
        // ponytail: one cap on the whole result rather than per string; the views clip every line anyway.
        guard data.count <= ExtensionLimits.resultBytes else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The result is over \(ExtensionLimits.resultBytes / 1024) KB"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601.plain.date(from: string) ?? ISO8601.fractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(string)"))
        }
        return try decoder.decode(ExtensionResult.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.plain.string(from: date))
        }
        return try encoder.encode(self)
    }

    /// Bounds what one result may ask for, so a script can't flood the island or the notification center.
    public func limited() -> ExtensionResult {
        var r = self
        r.reminders = reminders.map { Array($0.prefix(ExtensionLimits.reminders)) }
        r.actions = actions.map { Array($0.prefix(ExtensionLimits.actions)) }
        if var island = r.island {
            island.sections = Array(island.sections.prefix(ExtensionLimits.sections)).map { section in
                if case .list(let rows) = section { return .list(Array(rows.prefix(ExtensionLimits.rows))) }
                return section
            }
            r.island = island
        }
        return r
    }
}

enum ISO8601 {
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public enum ExtensionLimits {
    public static let reminders = 24
    /// A reminder must be set at least this far ahead, and no more than `remindersPerHour` go off in any hour.
    public static let reminderLead: TimeInterval = 60
    public static let remindersPerHour = 6
    public static let actions = 3
    public static let sections = 4
    public static let rows = 8
    /// A call (refresh, action) must answer within this.
    public static let callTimeout: Duration = .seconds(5)
    /// After a call that left the runner bigger than this, the host restarts it.
    public static let memoryBudgetBytes: UInt64 = 256 * 1024 * 1024
    public static let storageBytes = 64 * 1024
    /// A result (island, ear, reminders) larger than this is refused.
    public static let resultBytes = 32 * 1024
    public static let fetchBytes = 1024 * 1024
    public static let fetchTimeout: TimeInterval = 10
    /// Fetches one extension may have in flight; more fail at once.
    public static let fetchesInFlight = 4
}

// MARK: - What goes over XPC

/// What the host passes to a call: the settings, the extension's own storage, the time and the language.
public struct CallContext: Codable, Equatable, Sendable {
    public var settings: [String: JSONValue]
    public var storage: [String: JSONValue]
    public var now: String
    public var locale: String
    public var timeZone: String
    public var action: String?

    public init(settings: [String: JSONValue], storage: [String: JSONValue], now: Date, locale: String, timeZone: String, action: String? = nil) {
        self.settings = settings
        self.storage = storage
        self.now = ISO8601.plain.string(from: now)
        self.locale = locale
        self.timeZone = timeZone
        self.action = action
    }
}

/// What a call answers: the result (JSON as the script returned it) and the storage after the call.
public struct CallReply: Codable, Sendable {
    public var result: Data
    public var storage: [String: JSONValue]
    public var residentBytes: UInt64

    public init(result: Data, storage: [String: JSONValue], residentBytes: UInt64) {
        self.result = result
        self.storage = storage
        self.residentBytes = residentBytes
    }
}

public enum ExtensionXPC {
    public static let serviceName = "com.enbiyagoral.orilio.ExtensionRunner"
}

/// The runner, as the app sees it.
@objc public protocol ExtensionRunnerProtocol {
    /// Loads (or replaces) an extension's script. Replies with an error message, or nil.
    func load(extensionID: String, script: String, manifest: Data, reply: @escaping @Sendable (String?) -> Void)
    /// Calls `refresh`, `onAction` or `onSettingsChanged` with a JSON `CallContext`; replies with a JSON `CallReply` or an error.
    func call(extensionID: String, function: String, context: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    func unload(extensionID: String)
}

/// The app, as the runner sees it: the one thing a script may ask for, a fetch, checked by the app.
@objc public protocol ExtensionHostProtocol {
    func fetch(extensionID: String, url: String, method: String, body: Data?, reply: @escaping @Sendable (Data?, Int, String?) -> Void)
}
