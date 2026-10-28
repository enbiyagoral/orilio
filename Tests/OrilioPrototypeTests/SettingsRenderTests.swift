import AppKit
import SwiftUI
import Testing
@testable import OrilioPrototype

/// ORILIO_RENDER_SETTINGS=/path/dir swift test --filter SettingsRender
/// Draws each Settings pane, dark and light, for a side-by-side check against the M4 and M5 Settings designs.
@MainActor
struct SettingsRender {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_RENDER_SETTINGS"] != nil))
    func renderEveryPane() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_RENDER_SETTINGS"]!)
        let defaults = UserDefaults(suiteName: "orilio.render.\(UUID().uuidString)")!
        AppModules.modules = ModuleSettings(defaults: defaults)
        let calendar = CalendarModule(source: SampleCalendars(), reminders: NoReminders(), defaults: defaults)
        await calendar.enable()
        calendar.setCalendar("family", visible: false)
        AppModules.calendar = calendar
        AppModules.clipboard = ClipboardModule(store: ClipboardStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                               defaults: defaults)
        await AppModules.clipboard?.enable()
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for pane in SettingsView.Pane.allCases {
                let renderer = ImageRenderer(content: SettingsView(pane: pane, scrolls: false)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
                renderer.scale = 1
                var png: Data?
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    png = renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
                }
                try #require(png).write(to: directory.appending(path: "\(pane.rawValue)-\(name).png"))
            }
        }
    }
}

private struct NoReminders: ReminderScheduler {
    func authorize() async -> Bool { false }
    func replaceAll(_ reminders: [MeetingReminder]) async {}
}

/// The M5 Settings design's accounts.
private actor SampleCalendars: CalendarSource {
    func access() -> CalendarAccess { .authorized }
    func requestAccess() -> CalendarAccess { .authorized }
    func calendars() -> [CalendarInfo] {
        [("personal", "Personal", "iCloud", (1, 0.54, 0.48)), ("family", "Family", "iCloud", (1, 0.82, 0.48)),
         ("work", "Work", "Google", (0.43, 0.66, 1)), ("holidays", "Holidays in Türkiye", "Google", (0.48, 0.85, 0.63)),
         ("team", "Team", "Outlook", (0.79, 0.64, 1))]
            .map { CalendarInfo(id: $0.0, title: $0.1, sourceTitle: $0.2, color: CalendarColor(red: $0.3.0, green: $0.3.1, blue: $0.3.2)) }
    }
    func events(from start: Date, to end: Date) -> [CalendarEvent] { [] }
}
