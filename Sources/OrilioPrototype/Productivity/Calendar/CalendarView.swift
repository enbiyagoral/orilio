import AppKit
import SwiftUI

// Values follow the M3 hub design: a 290 pt "next" card (radius 22, padding 18) and a list of
// 38 pt rows (radius 12) on the right.
private enum Design {
    static let blue = Color(red: 0.43, green: 0.66, blue: 1)          // #6EA8FF
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
        switch module.status {
        case .ready:
            // Countdowns move once a minute, and only while the panel is on screen.
            TimelineView(.everyMinute) { context in
                CalendarToday(module: module, day: CalendarDay(events: module.day.events, now: fixedNow ?? context.date))
            }
        case .off, .needsAccess:
            CalendarMessage(symbol: "calendar", title: "See your next meeting here",
                            detail: "Orilio reads the calendars in the Calendar app (iCloud, Google, Exchange). Events stay on this Mac.",
                            action: ("Turn On Calendar", { Task { await module.enable() } }))
        case .denied:
            CalendarMessage(symbol: "calendar.badge.exclamationmark", title: "Calendar access is off",
                            detail: "Allow Orilio in System Settings › Privacy & Security › Calendars.",
                            action: ("Open System Settings", { NSWorkspace.shared.open(CalendarModule.privacySettingsURL) }))
        case .restricted:
            CalendarMessage(symbol: "lock", title: "Calendar access is restricted",
                            detail: "A device policy prevents apps from reading calendars on this Mac.", action: nil)
        }
    }
}

private struct CalendarToday: View {
    let module: CalendarModule
    let day: CalendarDay

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NextCard(module: module, day: day)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(summary)
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
                    ScrollView(.vertical, showsIndicators: false) { rows }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Five 38 pt rows fit under the header in the 266 pt content area; more scroll.
    static let rowsThatFit = 5

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(day.events) { event in
                EventRow(event: event, isNext: event.id == day.featured?.id, now: day.now)
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
                    .foregroundStyle(mint)
                Text(event?.title ?? "You're free")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.44)
                    .lineLimit(2)
                if let event {
                    Text(timeLine(event))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
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
                                .background(mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: mint.opacity(0.4), radius: 12)
                        }
                        .buttonStyle(PressableStyle())
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
        .help("Open in Calendar")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title), \(event.isAllDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened)), \(event.calendarTitle)")
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

private struct CalendarMessage: View {
    let symbol: String
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Design.blue)
                .frame(width: 64, height: 64)
                .background(Design.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action: action.1) {
                        Text(action.0)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Design.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(mint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The collapsed island while a meeting is about to start: dot and title left of the notch,
/// countdown right of it.
struct MeetingPill: View {
    let event: CalendarEvent
    let now: Date

    var body: some View {
        HStack {
            HStack(spacing: 7) {
                Circle().fill(event.color.color).frame(width: 7, height: 7)
                Text(event.title).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(CalendarDay.countdown(to: event.start, from: now))
                .foregroundStyle(mint)
                .shadow(color: mint.opacity(0.55), radius: 5)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title) \(CalendarDay.countdown(to: event.start, from: now)). Open island")
    }
}
