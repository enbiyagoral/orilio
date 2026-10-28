// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// One event, copied out of EventKit into a plain value so views never touch the event store.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    /// Unique per occurrence: recurring events share an identifier, so the start is part of it.
    let id: String
    /// EventKit's identifier, used to open the event in Calendar.
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    /// The account the calendar belongs to, as macOS names it ("iCloud", "Google", "Exchange"…).
    let sourceTitle: String
    /// sRGB components of the calendar's color.
    let color: CalendarColor
    let attendeeNames: [String]
    let meeting: MeetingLink?

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
    func hasEnded(at now: Date) -> Bool { end <= now }
}

struct CalendarColor: Equatable, Sendable {
    var red: Double, green: Double, blue: Double
    static let fallback = CalendarColor(red: 0.43, green: 0.66, blue: 1) // #6EA8FF, the design's calendar blue
}

struct CalendarInfo: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    let color: CalendarColor
}

enum CalendarAccess: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

/// A meeting link that was found in an event and checked before Orilio will offer to open it.
struct MeetingLink: Equatable, Sendable {
    enum Provider: String, Sendable {
        case googleMeet = "Google Meet"
        case zoom = "Zoom"
        case teams = "Microsoft Teams"
    }

    let provider: Provider
    let url: URL
}

/// Finds Google Meet, Zoom and Teams links in event fields. Conservative on purpose:
/// only `https`, only the providers' own hosts, only their meeting paths. Text is never run or
/// interpreted; anything that doesn't match is ignored.
enum MeetingLinkResolver {
    /// The event's own URL first, then location, then notes (notes are often long invitations).
    static func resolve(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = validate(url) { return link }
        for text in [location, notes].compactMap({ $0 }) {
            for candidate in candidates(in: text) {
                if let link = validate(candidate) { return link }
            }
        }
        return nil
    }

    static func candidates(in text: String) -> [URL] {
        // Bounded: very long notes are scanned only in their first 20 000 characters.
        let sample = String(text.prefix(20_000))
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)).compactMap(\.url)
    }

    static func validate(_ url: URL) -> MeetingLink? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if host == "meet.google.com", path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil {
            return MeetingLink(provider: .googleMeet, url: url)
        }
        if on("zoom.us"), path.range(of: #"^/(j|my|s|w)/[a-z0-9.\-_]+$"#, options: .regularExpression) != nil {
            return MeetingLink(provider: .zoom, url: url)
        }
        if (host == "teams.microsoft.com" && path.hasPrefix("/l/meetup-join/"))
            || (host == "teams.live.com" && path.hasPrefix("/meet/")) {
            return MeetingLink(provider: .teams, url: url)
        }
        return nil
    }
}

/// Today's events, interpreted at a moment. Pure, so every rule is unit-tested with a fixed clock.
struct CalendarDay: Equatable, Sendable {
    let events: [CalendarEvent] // sorted by start
    let now: Date

    var timed: [CalendarEvent] { events.filter { !$0.isAllDay } }
    var allDay: [CalendarEvent] { events.filter(\.isAllDay) }

    /// What the big card shows: the meeting in progress, else the next one to start.
    var featured: CalendarEvent? { current ?? next }
    var current: CalendarEvent? { timed.last { $0.isOngoing(at: now) } }
    var next: CalendarEvent? { timed.first { $0.start > now } }

    /// For the collapsed island: an event starting within `window`, or one that started a moment ago.
    func soon(within window: TimeInterval = 10 * 60, justStarted: TimeInterval = 5 * 60) -> CalendarEvent? {
        timed.first { event in
            let lead = event.start.timeIntervalSince(now)
            return (lead > 0 && lead <= window) || (lead <= 0 && -lead < justStarted && event.end > now)
        }
    }

    /// When this interpretation goes stale with no new data: an event starting or ending, or
    /// entering or leaving the "soon" window the collapsed island shows.
    func nextBoundary(window: TimeInterval = 10 * 60, justStarted: TimeInterval = 5 * 60) -> Date? {
        timed.flatMap { [$0.start.addingTimeInterval(-window), $0.start, $0.start.addingTimeInterval(justStarted), $0.end] }
            .filter { $0 > now }.min()
    }

    var calendarCount: Int { Set(events.map(\.calendarID)).count }

    /// Timed events that share time with another one (the amber "Overlaps" tag). Back-to-back isn't an overlap.
    var overlapping: Set<String> {
        let timed = self.timed.sorted { $0.start < $1.start }
        var ids = Set<String>()
        for (i, a) in timed.enumerated() {
            for b in timed[(i + 1)...] {
                guard b.start < a.end else { break }
                ids.insert(a.id)
                ids.insert(b.id)
            }
        }
        return ids
    }

    /// "in 4 min", "in 1 h 20 min", "now".
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
