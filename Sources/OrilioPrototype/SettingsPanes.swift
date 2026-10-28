import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The M5 Settings design's panes: General, Calendar, Clipboard, Shortcuts, Updates and About.

private typealias Design = SettingsDesign

/// A card row of the M5 design: 56 pt, a 13.5 pt title and a 12 pt note, the control on the right.
private struct PaneRow<Control: View>: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = Design.secondary
    var titleSize: CGFloat = 13.5
    var titleWeight: Font.Weight = .regular
    var height: CGFloat = 56
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: titleSize, weight: titleWeight))
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(noteColor).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 16)
        .frame(minHeight: height)
    }
}

/// The design's 34 pt buttons (10% ink, radius 9).
private struct PaneButton: View {
    let title: String
    var background = Design.ink.opacity(0.1)
    var foreground = Design.ink
    var weight: Font.Weight = .medium
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

/// The language Orilio asks macOS for (`AppleLanguages` in Orilio's own defaults); read at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, tr
    var id: Self { self }

    static var current: AppLanguage {
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
        return own?.first.flatMap { code in allCases.first { $0 != .system && code.hasPrefix($0.rawValue) } } ?? .system
    }

    /// What Orilio started with: a change shows "Restart Orilio to apply".
    static let atLaunch = current

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    var title: String {
        switch self {
        case .system: "System (\(Self.systemName))"
        case .en: "English"
        case .tr: "Türkçe"
        }
    }

    /// The Mac's own first language, in that language ("Türkçe").
    private static var systemName: String {
        let code = (CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String])?.first ?? "en"
        let name = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

struct GeneralPane: View {
    @Bindable var store: PreferencesStore
    @State private var language = AppLanguage.current
    @State private var notice: (text: String, failed: Bool)?

    var body: some View {
        let p = store.value
        VStack(alignment: .leading, spacing: 22) {
            Card {
                PaneRow(title: "Language", note: language == AppLanguage.atLaunch ? nil : "Restart Orilio to apply", noteColor: Design.warn) {
                    PopUpButton(options: AppLanguage.allCases.map { ($0, $0.title) }, selection: language) {
                        language = $0
                        $0.apply()
                    }
                }
                RowLine()
                toggle("Open on hover", "Off: the island opens only on click or shortcut", \.openOnHover)
                RowLine()
                toggle("Trackpad haptics", "A light tap when the island opens or snaps", \.haptics)
                RowLine()
                toggle("Sounds", "A soft chime when a focus session ends", \.sounds)
                RowLine()
                PaneRow(title: "Hover delay", note: "How long to rest on the notch before it peeks") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(p.hoverDelay) }, set: { store.value.hoverDelay = Int($0.rounded()) }), in: 0...500)
                            .tint(Design.accent)
                            .controlSize(.small)
                            .frame(width: 180)
                            .accessibilityLabel("Hover delay")
                        Text("\(p.hoverDelay) ms").font(.system(size: 12)).foregroundStyle(Design.ink.opacity(0.7))
                            .frame(width: 48, alignment: .leading)
                    }
                }
            }
            HStack(spacing: 8) {
                PaneButton(title: "Replay onboarding") {
                    OnboardingModel.reset()
                    AppModules.island?.startOnboarding()
                }
                PaneButton(title: "Export settings…", action: exportSettings)
                PaneButton(title: "Import settings…", action: importSettings)
            }
            if let notice {
                Text(notice.text).font(.system(size: 12)).foregroundStyle(notice.failed ? Design.warn : Design.secondary)
            }
        }
    }

    private func toggle(_ title: String, _ note: String, _ key: WritableKeyPath<Preferences, Bool>) -> some View {
        PaneRow(title: title, note: note) {
            DesignSwitch(isOn: store.value[keyPath: key], label: title) { store.value[keyPath: key].toggle() }
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orilio Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.value.exported().write(to: url, options: .atomic)
            notice = ("Settings exported to \(url.lastPathComponent).", false)
        } catch {
            notice = (error.localizedDescription, true)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            store.value = try Preferences.imported(from: Data(contentsOf: url))
            notice = ("Settings imported from \(url.lastPathComponent).", false)
        } catch {
            notice = (error.localizedDescription, true)
        }
    }
}

/// The design's select: a 30 pt, 10% ink field that opens a native menu.
private struct PopUpButton<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value
    let pick: (Value) -> Void

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "").font(.system(size: 13))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Design.ink.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Design.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func popUp() {
        let menu = NSMenu()
        for (value, title) in options {
            let item = ClosureMenuItem(title: title) { pick(value) }
            item.state = value == selection ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

// MARK: - Calendar

/// Calendars grouped by account, in the order EventKit lists them.
enum CalendarGroups {
    static func group(_ calendars: [CalendarInfo]) -> [(account: String, calendars: [CalendarInfo])] {
        var groups: [(account: String, calendars: [CalendarInfo])] = []
        for calendar in calendars {
            if let i = groups.firstIndex(where: { $0.account == calendar.sourceTitle }) {
                groups[i].calendars.append(calendar)
            } else {
                groups.append((calendar.sourceTitle, [calendar]))
            }
        }
        return groups
    }
}

struct CalendarPane: View {
    var body: some View {
        if let module = AppModules.calendar { CalendarPaneContent(module: module) }
    }
}

private struct CalendarPaneContent: View {
    let module: CalendarModule
    @State private var lead: Int

    init(module: CalendarModule) {
        self.module = module
        _lead = State(initialValue: module.meetingLeadMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if module.status != .ready { access }
            if !module.calendars.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Calendars shown in the island")
                    Card {
                        ForEach(CalendarGroups.group(module.calendars), id: \.account) { group in
                            Text(group.account.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.66)
                                .foregroundStyle(Design.ink.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                            ForEach(group.calendars) { calendar in CalendarRow(module: module, calendar: calendar) }
                        }
                    }
                }
            }
            HStack {
                SectionLabel("Show an upcoming meeting in the notch")
                Spacer()
                Segmented(options: [(10, "10 min before"), (5, "5 min before"), (0, "At start")], selection: lead) {
                    lead = $0
                    module.setMeetingLead($0)
                }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Join links detected")
                    Text("From the event’s location, notes or URL field").font(.system(size: 12)).foregroundStyle(Design.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(["Google Meet", "Zoom", "Microsoft Teams", "Webex"], id: \.self) { name in
                        Text(name).font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Design.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    /// Calendar is off or macOS says no: the one row that gets it going.
    private var access: some View {
        Card {
            switch module.status {
            case .denied:
                PaneRow(title: "Calendar access is off", note: "Allow Orilio in Privacy & Security › Calendars.", noteColor: Design.warn) {
                    DesignButton(title: "Open System Settings…") { NSWorkspace.shared.open(CalendarModule.privacySettingsURL) }
                }
            case .restricted:
                PaneRow(title: "Calendar access is restricted on this Mac", note: "A profile or Screen Time limits it.") { EmptyView() }
            default:
                PaneRow(title: "Show your meetings in the island", note: "Orilio reads the calendars on this Mac; macOS asks first.") {
                    DesignButton(title: "Turn On") { Task { await module.enable() } }
                }
            }
        }
    }
}

private struct CalendarRow: View {
    let module: CalendarModule
    let calendar: CalendarInfo

    var body: some View {
        let on = !module.hiddenCalendarIDs.contains(calendar.id)
        Button { module.setCalendar(calendar.id, visible: !on) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? Design.accent : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Design.ink.opacity(on ? 0 : 0.35), lineWidth: 1.5))
                    .overlay {
                        if on { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Design.hex(0x00140D)) }
                    }
                    .frame(width: 18, height: 18)
                Circle().fill(calendar.color.color).frame(width: 8, height: 8)
                Text(calendar.title).font(.system(size: 13.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.title)
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Clipboard

struct ClipboardPane: View {
    var body: some View {
        if let module = AppModules.clipboard { ClipboardPaneContent(module: module) }
    }
}

private struct ClipboardPaneContent: View {
    let module: ClipboardModule
    @State private var retention: Int
    @State private var bytes = 0
    @State private var selectedApp: String?
    @State private var confirmClear = false

    init(module: ClipboardModule) {
        self.module = module
        _retention = State(initialValue: module.retentionDays)
    }

    var body: some View {
        let on = module.status != .off
        VStack(alignment: .leading, spacing: 22) {
            Card {
                PaneRow(title: "Keep clipboard history",
                        note: module.status == .blocked ? "macOS denies Orilio reading other apps’ copies." : "Stored only on this Mac, never synced",
                        noteColor: module.status == .blocked ? Design.warn : Design.secondary,
                        titleSize: 14, titleWeight: .medium, height: 60) {
                    DesignSwitch(isOn: on, label: "Keep clipboard history") {
                        Task {
                            on ? await module.disable() : await module.enable()
                            bytes = await module.diskBytes()
                        }
                    }
                }
                RowLine()
                PaneRow(title: "Keep items for") {
                    Segmented(options: [(1, "1 day"), (7, "7 days"), (30, "30 days")], selection: retention, pick: {
                        retention = $0
                        module.setRetention(days: $0)
                    }, compact: true)
                }
                RowLine()
                PaneRow(title: "Always skip hidden and temporary items", note: "Passwords and one-time codes marked as concealed are never saved") {
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 11, weight: .semibold))
                        Text("Always on")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Design.ink.opacity(0.55))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Never record from these apps")
                Card {
                    ExcludedRow(name: "Password managers", note: "Detected automatically",
                                tile: [Design.hex(0x3A6FD8), Design.hex(0x1E3F8A)])
                    RowLine()
                    ExcludedRow(name: "Keychain Access", note: "Added by default", tile: [Design.hex(0x8E8E93), Design.hex(0x48484A)])
                    ForEach(module.userExcludedApps, id: \.self) { id in
                        RowLine()
                        ExcludedRow(name: AppInfo.name(id), note: "Added by you", icon: AppInfo.icon(id), selected: selectedApp == id)
                            .onTapGesture { selectedApp = selectedApp == id ? nil : id }
                    }
                    RowLine()
                    HStack(spacing: 4) {
                        Button(action: addApp) {
                            Text("+").font(.system(size: 18)).frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add app")
                        Button {
                            if let selectedApp { module.removeExcludedApp(selectedApp) }
                            selectedApp = nil
                        } label: {
                            Text("−").font(.system(size: 18)).foregroundStyle(Design.ink.opacity(0.5)).frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedApp == nil)
                        .accessibilityLabel("Remove app")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                }
            }

            HStack {
                Text("\(module.items.count) \(module.items.count == 1 ? "item" : "items") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) on disk")
                    .font(.system(size: 12.5)).foregroundStyle(Design.secondary)
                Spacer()
                PaneButton(title: "Clear history…", background: Design.dangerFill, foreground: Design.danger, weight: .semibold) { confirmClear = true }
                    .disabled(module.items.allSatisfy(\.pinned))
            }
        }
        .task(id: module.items.count) {
            try? await Task.sleep(for: .milliseconds(400)) // after the coalesced save
            bytes = await module.diskBytes()
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { module.clear() }
        } message: {
            Text("Every item except pinned ones is deleted from this Mac.")
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { module.addExcludedApp(id) } }
    }
}

private extension SettingsDesign {
    static let danger = adaptive(dark: ns(0xFF9A9A), light: ns(0xC4001A))
    static let dangerFill = adaptive(dark: NSColor(srgbRed: 1, green: 107 / 255, blue: 107 / 255, alpha: 0.16),
                                     light: NSColor(srgbRed: 215 / 255, green: 0, blue: 21 / 255, alpha: 0.08))
}

/// Name and icon of an app by bundle identifier, from where macOS finds it.
private enum AppInfo {
    static func name(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    static func icon(_ id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

private struct ExcludedRow: View {
    let name: String
    let note: String
    var tile: [Color] = []
    var icon: NSImage? = nil
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    LinearGradient(colors: tile, startPoint: UnitPoint(x: 0.16, y: 0.03), endPoint: UnitPoint(x: 0.84, y: 0.97))
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(name).font(.system(size: 13.5))
            Spacer(minLength: 0)
            Text(note).font(.system(size: 12)).foregroundStyle(Design.ink.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(selected ? Design.selected : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @Bindable var store: PreferencesStore
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?

    var body: some View {
        let hidden = AppModules.modules?.hidden ?? []
        let conflicts = GlobalHotKeys.shared.conflicts
        VStack(alignment: .leading, spacing: 22) {
            Text("Global shortcuts work in every app. Click one to record a new combination.")
                .font(.system(size: 12.5)).foregroundStyle(Design.ink.opacity(0.55))
            Card {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    let off = action.module.map(hidden.contains) ?? false
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol).font(.system(size: 14)).foregroundStyle(Design.ink.opacity(0.75)).frame(width: 17)
                        Text(action.title).font(.system(size: 13.5))
                        Spacer(minLength: 0)
                        if off {
                            Text("Module hidden").font(.system(size: 12)).foregroundStyle(Design.secondary)
                        } else if conflicts.contains(action), recording != action {
                            Text("Already in use").font(.system(size: 12)).foregroundStyle(Design.warn)
                        }
                        Recorder(combo: store.value.shortcut(action), recording: recording == action) { toggleRecording(action) }
                            .disabled(off)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .opacity(off ? 0.45 : 1)
                    if index < ShortcutAction.allCases.count - 1 { RowLine() }
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording(_ action: ShortcutAction) {
        let same = recording == action
        stopRecording()
        guard !same else { return }
        recording = action
        GlobalHotKeys.shared.paused = true // the current combination has to reach the recorder
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stopRecording() // Esc cancels
            case 51, 117: save(.none, for: action) // Delete clears
            default:
                guard let combo = HotKeyCombo(event: event) else { NSSound.beep(); return nil } // needs ⌃, ⌥ or ⌘
                save(combo, for: action)
            }
            return nil
        }
    }

    private func save(_ combo: HotKeyCombo, for action: ShortcutAction) {
        store.value.shortcuts[action.rawValue] = combo
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        GlobalHotKeys.shared.paused = false
    }
}

/// The design's recorder: keycaps on a 6% plate; mint "Press keys…" while recording.
private struct Recorder: View {
    let combo: HotKeyCombo
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if recording {
                    Text("Press keys…").foregroundStyle(Design.accentText)
                } else if combo.isNone {
                    Text("Record shortcut").foregroundStyle(Design.secondary)
                } else {
                    ForEach(combo.keycaps, id: \.self) { key in
                        Text(key).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Design.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 10)
            .frame(minWidth: 120, minHeight: 32)
            .background(recording ? Design.accent.opacity(0.12) : Design.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(recording ? Design.accent : Design.ink.opacity(0.08), lineWidth: recording ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(recording ? "Recording, press keys" : combo.isNone ? "No shortcut" : combo.spoken)
    }
}

// MARK: - Updates (M5.6 fills this in)

struct UpdatesPane: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(Design.accentText)
                .frame(width: 48, height: 48)
                .background(Design.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("You have Orilio \(AboutPane.version)").font(.system(size: 16, weight: .semibold))
                Text("Automatic updates arrive in a later version.").font(.system(size: 12.5)).foregroundStyle(Design.ink.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Design.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Design.cardStroke, lineWidth: 1))
    }
}

// MARK: - About

struct AboutPane: View {
    @State private var acknowledgements = false
    @State private var feedbackSoon = false

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–" }

    var body: some View {
        VStack(spacing: 14) {
            AppIcon()
            Text("Orilio").font(.system(size: 30, weight: .semibold)).tracking(-0.9)
            Text("Version \(Self.version) (\(Self.build))").font(.system(size: 13)).foregroundStyle(Design.ink.opacity(0.55))
            Text("Free, for everyone. No account, no ads, no tracking.").font(.system(size: 15)).foregroundStyle(Design.ink.opacity(0.85))
            HStack(spacing: 8) {
                PaneButton(title: "Send feedback") { feedbackSoon = true }
                PaneButton(title: "Acknowledgements") { acknowledgements = true }
            }
            .padding(.top, 6)
            Text("Made by Enbiya Goral").font(.system(size: 12)).foregroundStyle(Design.ink.opacity(0.4)).padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 760 - 53 - 48)
        .sheet(isPresented: $acknowledgements) { Acknowledgements() }
        .alert("Feedback comes with the next version", isPresented: $feedbackSoon) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// The design's app icon: a dark tile with the notch and its mint light.
private struct AppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(colors: [Design.hex(0x1B2233), Design.hex(0x07080C)], startPoint: UnitPoint(x: 0.33, y: 0.03), endPoint: UnitPoint(x: 0.67, y: 0.97)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 50, height: 16)
                    Capsule().fill(Design.mint).frame(width: 22, height: 5).shadow(color: Design.mint, radius: 6).padding(.top, 5)
                }
            }
            .frame(width: 112, height: 112)
            .shadow(color: .black.opacity(0.5), radius: 25, y: 22)
            .accessibilityHidden(true)
    }
}

private struct Acknowledgements: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acknowledgements").font(.system(size: 15, weight: .semibold))
            Text("Orilio is built only on Apple’s frameworks. Some of its icons follow Lucide’s geometry.")
                .font(.system(size: 13)).foregroundStyle(Design.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Lucide · ISC License").font(.system(size: 13, weight: .semibold))
                Text(Self.lucide).font(.system(size: 11.5)).foregroundStyle(Design.ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Design.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Design.cardStroke, lineWidth: 1))
            HStack {
                Spacer()
                PaneButton(title: "Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .foregroundStyle(Design.ink)
        .background(Design.window)
    }

    static let lucide = """
    Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). \
    All other copyright (c) for Lucide are held by Lucide Contributors 2022.

    Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee \
    is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE \
    INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE \
    FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS \
    OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING \
    OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
    """
}
