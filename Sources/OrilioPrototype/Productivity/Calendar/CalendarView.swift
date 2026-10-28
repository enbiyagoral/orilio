// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Network
import SwiftUI

// Values follow the M3 hub design: a 290 pt "next" card (radius 22, padding 18) and a list of
// 38 pt rows (radius 12) on the right.
private enum Design {
    static let blue = Color(red: 0.43, green: 0.66, blue: 1)          // #6EA8FF
    static let lightBlue = Color(red: 0.553, green: 0.733, blue: 1)   // #8DBBFF
    static let ink = Color(red: 0, green: 0.078, blue: 0.051)         // #00140D, text on the accent
    static let avatarColors = [Color(red: 0.23, green: 0.29, blue: 0.42), // #3B4A6B
                               Color(red: 0.35, green: 0.25, blue: 0.42), // #5A3F6B
                               Color(red: 0.18, green: 0.35, blue: 0.33)] // #2F5A55
    static let cardFill = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.08)
}

extension CalendarColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// The Calendar module in the island.
struct CalendarPanel: View {
    let module: CalendarModule
    /// A fixed moment instead of the clock (for rendering a known day in a visual check).
    var fixedNow: Date? = nil

    var body: some View {
        // Countdowns move once a minute, and only while the panel is on screen.
        TimelineView(.everyMinute) { context in
            let now = fixedNow ?? max(context.date, Date()) // the schedule's date is the minute's start
            let day = CalendarDay(events: module.day.events, now: now)
            card(CalendarCardState.resolve(status: module.status, declined: module.declined, calendarCount: module.calendars.count,
                                           day: day, nextLater: module.nextLater, offline: NetworkStatus.shared.offline), day: day)
        }
        // Access can be revoked in System Settings at any time: re-check each time the module opens.
        .onAppear { if module.status != .off { module.refresh() } }
    }

    @ViewBuilder private func card(_ state: CalendarCardState, day: CalendarDay) -> some View {
        switch state {
        case .ask:
            StatusCard(tone: .ask(tile: Design.blue.opacity(0.16), ink: Design.lightBlue), symbol: "calendar",
                       title: "Show your meetings up here?",
                       detail: "Orilio reads events from calendars already added to this Mac — iCloud, Google, Outlook. Nothing leaves your Mac.",
                       primary: .init("Continue") { Task { await module.enable() } },
                       secondary: .init("Not now") { module.decline() }, layout: .ask)
        case .declined:
            StatusCard(tone: .warn, symbol: "exclamationmark.shield", title: "Calendar access is off",
                       detail: "Orilio can’t see your events until access is turned back on.",
                       primary: .init("Turn on") { Task { await module.enable() } })
        case .denied:
            StatusCard(tone: .warn, symbol: "calendar.badge.exclamationmark", title: "Calendar access is off",
                       detail: "Turn on Orilio in Privacy & Security › Calendars to see your meetings.",
                       primary: .init("Open System Settings") { PrivacyPane.open(PrivacyPane.calendars) }, layout: .banner)
                .frame(maxHeight: .infinity)
        case .restricted:
            StatusCard(tone: .empty, symbol: "lock", title: "Calendar access is restricted",
                       detail: "A device policy prevents apps from reading calendars on this Mac.")
        case .noCalendars:
            StatusCard(tone: .empty, symbol: "calendar", title: "No calendars on this Mac",
                       detail: "Add iCloud, Google or Outlook in System Settings › Internet Accounts.",
                       primary: .init("Open Internet Accounts") { PrivacyPane.open(PrivacyPane.internetAccounts) })
        case .clearRestOfDay(let next):
            StatusCard(tone: .good, symbol: "calendar.badge.checkmark", title: "Nothing else today",
                       detail: next.map { "Next up: \($0.title), \(Self.when($0.start, from: day.now))." } ?? "Nothing on your calendars this week.")
        case .events(let offline):
            CalendarToday(module: module, day: day, offline: offline)
        }
    }

    /// "tomorrow at 09:30", or "Friday at 09:30".
    static func when(_ date: Date, from now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(date, inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now) {
            return "tomorrow at \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)"
    }
}

private struct CalendarToday: View {
    let module: CalendarModule
    let day: CalendarDay
    var offline = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NextCard(module: module, day: day)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    // Offline: EventKit's events still show; joining has to wait for the network.
                    Text(offline ? "Offline · Join links work once you’re back online" : summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 6)
                if day.events.isEmpty {
                    Text("Nothing else on your calendars today.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if day.events.count <= Self.rowsThatFit {
                    rows
                } else {
                    // More than fit: the list scrolls with a soft fade, and a pill counts what's still to come below.
                    let below = day.events.dropFirst(Self.rowsThatFit).filter { !$0.hasEnded(at: day.now) }.count
                    ScrollView(.vertical, showsIndicators: false) { rows.padding(.bottom, 28) }
                        .bottomFade(true)
                        .overlay(alignment: .bottom) {
                            if below > 0 { CountPill(text: "+\(below) later today").padding(.bottom, 4).allowsHitTesting(false) }
                        }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Five 38 pt rows fit under the header in the 266 pt content area; more scroll.
    static let rowsThatFit = 5

    private var rows: some View {
        let overlapping = day.overlapping
        return VStack(spacing: 4) {
            ForEach(day.events) { event in
                EventRow(event: event, isNext: event.id == day.featured?.id, overlaps: overlapping.contains(event.id), now: day.now)
                    .onTapGesture { module.openInCalendar(event) }
            }
        }
    }

    private var summary: String {
        let events = day.events.count, calendars = day.calendarCount
        return "\(events) event\(events == 1 ? "" : "s") · \(calendars) calendar\(calendars == 1 ? "" : "s")"
    }
}

private struct NextCard: View {
    let module: CalendarModule
    let day: CalendarDay

    var body: some View {
        let event = day.featured
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow(event))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.32) // 0.12 em
                    .foregroundStyle(accent(.live))
                Text(event?.title ?? "You're free")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.44)
                    .lineLimit(2) // then an ellipsis; the full title is in the tooltip and for VoiceOver
                    .help(event?.title ?? "")
                if let event {
                    Text(timeLine(event))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .help(timeLine(event))
                    Attendees(event: event).padding(.top, 4)
                } else {
                    Text("No more meetings today.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            Spacer(minLength: 8)
            if let event {
                HStack(spacing: 8) {
                    if event.meeting != nil {
                        Button { module.join(event) } label: {
                            Label("Join meeting", systemImage: "video")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Design.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(accent(.action), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .themeGlow(.action, radius: 12, opacity: 0.4)
                        }
                        .buttonStyle(PressableStyle())
                        .keyboardFocusRing(true, radius: 14) // ⏎ joins
                        .accessibilityHint("Opens the \(event.meeting!.provider.rawValue) link in your browser or the meeting app")
                    } else {
                        Button { module.openInCalendar(event) } label: {
                            Label("Open in Calendar", systemImage: "calendar")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                    ReminderMenu(module: module)
                }
            }
        }
        .padding(18)
        .frame(width: 290)
        .frame(maxHeight: .infinity)
        .background {
            shape.fill(Design.cardFill)
            shape.fill(RadialGradient(colors: [Design.blue.opacity(0.22), .clear], center: .topLeading,
                                      startRadius: 0, endRadius: 260))
        }
        .overlay(shape.strokeBorder(Design.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func eyebrow(_ event: CalendarEvent?) -> String {
        guard let event else { return "TODAY" }
        if event.isOngoing(at: day.now) { return "NOW · ENDS \(CalendarDay.countdown(to: event.end, from: day.now).uppercased())" }
        return "NEXT · \(CalendarDay.countdown(to: event.start, from: day.now).uppercased())"
    }

    private func timeLine(_ event: CalendarEvent) -> String {
        let range = "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        return [range, event.meeting?.provider.rawValue].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct Attendees: View {
    let event: CalendarEvent

    var body: some View {
        let names = event.attendeeNames
        HStack(spacing: 6) {
            HStack(spacing: -10) {
                ForEach(Array(names.prefix(2).enumerated()), id: \.offset) { index, name in
                    avatar(CalendarDay.initials(name), Design.avatarColors[index])
                }
                if names.count > 2 { avatar("+\(names.count - 2)", Design.avatarColors[2]) }
            }
            Text(event.sourceTitle.isEmpty ? event.calendarTitle : event.sourceTitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.isEmpty ? event.calendarTitle : "\(names.count) attendees, \(event.calendarTitle)")
    }

    private func avatar(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 24, height: 24)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(Color(red: 0.043, green: 0.043, blue: 0.059), lineWidth: 2)) // #0B0B0F ring
    }
}

/// Meeting reminders for every event: at start, 5 or 10 minutes before, or off.
private struct ReminderMenu: View {
    let module: CalendarModule

    var body: some View {
        Menu {
            Picker("Remind me", selection: Binding(get: { module.reminderLeadMinutes },
                                                   set: { lead in Task { await module.setReminderLead(lead) } })) {
                Text("Off").tag(-1)
                Text("At start").tag(0)
                Text("5 minutes before").tag(5)
                Text("10 minutes before").tag(10)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: module.reminderLeadMinutes >= 0 ? "alarm.fill" : "alarm")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Meeting reminders")
        .accessibilityLabel("Meeting reminders")
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let isNext: Bool
    var overlaps = false
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Text(event.isAllDay ? "All day" : event.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 40, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(event.color.color).frame(width: 3, height: 20)
            Text(event.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if overlaps {
                Text("Overlaps")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SettingsDesign.amber)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(SettingsDesign.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .fixedSize()
            }
            Text(source)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(isNext ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(event.hasEnded(at: now) ? 0.45 : 1)
        .contentShape(Rectangle())
        .help("\(event.title) · Open in Calendar") // the full title, however long
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title), \(event.isAllDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened)), \(event.calendarTitle)\(overlaps ? ", overlaps another event" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private var source: String {
        let provider: String? = switch event.meeting?.provider {
        case .googleMeet: "Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        case nil: nil
        }
        let account = event.sourceTitle.isEmpty ? event.calendarTitle : event.sourceTitle
        return [account, provider].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Whether the Mac has a network path, from the system (no traffic of its own). Only the
/// calendar's Offline line reads it.
@MainActor @Observable
final class NetworkStatus {
    static let shared = NetworkStatus()
    private(set) var offline = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor in NetworkStatus.shared.offline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "com.enbiyagoral.orilio.network"))
    }
}
