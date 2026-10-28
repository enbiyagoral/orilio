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
            Section {
                Text("Spotify and Music are read through their public notifications and controlled with Apple Events after you allow it. Calendar events are read from the Calendar app on this Mac. No analytics; the only network use is loading cover art from the music services.")
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
