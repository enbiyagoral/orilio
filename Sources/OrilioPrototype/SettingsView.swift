import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.openOnHover) private var openOnHover = true
    @AppStorage(SettingsKeys.preferNotchedDisplay) private var preferNotchedDisplay = false
    @AppStorage(SettingsKeys.showDemoSource) private var showDemoSource = false

    var body: some View {
        Form {
            Section {
                Toggle("Open the island on hover", isOn: $openOnHover)
                Toggle("Show on the built-in notched display when connected", isOn: $preferNotchedDisplay)
                Toggle("Show the Demo media source", isOn: $showDemoSource)
            }
            if let calendar = AppModules.calendar {
                CalendarSettings(module: calendar)
            }
            if let clipboard = AppModules.clipboard {
                ClipboardSettings(module: clipboard)
            }
            Section {
                Text("Spotify and Music are read through their public notifications and controlled with Apple Events after you allow it. Calendar events are read from the Calendar app on this Mac. Clipboard history stays on this Mac. No analytics; the only network use is loading cover art from the music services.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Calendar on/off, which calendars to show, and meeting reminders. Turning Calendar on is the
/// only thing that asks for calendar access; choosing a reminder is the only thing that asks to
/// send notifications.
private struct CalendarSettings: View {
    let module: CalendarModule

    var body: some View {
        Section("Calendar") {
            Toggle("Show today's events and meetings", isOn: Binding(
                get: { module.status != .off },
                set: { on in if on { Task { await module.enable() } } else { module.disable() } }))
            if module.status != .off {
                switch module.status {
                case .denied:
                    LabeledContent("Access") {
                        Button("Open System Settings…") { NSWorkspace.shared.open(CalendarModule.privacySettingsURL) }
                    }
                case .restricted:
                    Text("Calendar access is restricted on this Mac.").foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Picker("Meeting reminders", selection: Binding(
                    get: { module.reminderLeadMinutes },
                    set: { lead in Task { await module.setReminderLead(lead) } })) {
                    Text("Off").tag(-1)
                    Text("At start").tag(0)
                    Text("5 minutes before").tag(5)
                    Text("10 minutes before").tag(10)
                }
                ForEach(module.calendars) { calendar in
                    Toggle(isOn: Binding(get: { !module.hiddenCalendarIDs.contains(calendar.id) },
                                         set: { module.setCalendar(calendar.id, visible: $0) })) {
                        HStack(spacing: 8) {
                            Circle().fill(calendar.color.color).frame(width: 9, height: 9)
                            Text(calendar.title)
                            Text(calendar.sourceTitle).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Clipboard history on/off, pause, limits and the apps it never records from. Turning it off
/// deletes the stored history.
private struct ClipboardSettings: View {
    let module: ClipboardModule

    var body: some View {
        Section("Clipboard") {
            Toggle("Keep a clipboard history", isOn: Binding(
                get: { module.status != .off },
                set: { on in Task { on ? await module.enable() : await module.disable() } }))
            if module.status == .blocked {
                LabeledContent("Access") {
                    Button("Open System Settings…") { NSWorkspace.shared.open(ClipboardModule.pasteSettingsURL) }
                }
            } else if module.status != .off {
                Toggle("Pause recording", isOn: Binding(
                    get: { module.status == .paused },
                    set: { $0 ? module.pause() : module.resume() }))
                Picker("Keep items for", selection: Binding(get: { module.retentionDays }, set: { module.setRetention(days: $0) })) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Until removed").tag(0)
                }
                Picker("Keep at most", selection: Binding(get: { module.maxItems }, set: { module.setMaxItems($0) })) {
                    Text("50 items").tag(50)
                    Text("200 items").tag(200)
                    Text("500 items").tag(500)
                }
                LabeledContent("History") {
                    Button("Clear Unpinned Items") { module.clear() }
                }
                Text("Turning history off deletes it. Items marked private by apps, and copies made while a password manager is in front, are never recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
