import AppKit
import SwiftUI

/// The Settings window: a sidebar of panes (the M4 Settings design).
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case modules = "Modules", appearance = "Appearance", displays = "Displays", startup = "Startup"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .modules: "square.grid.2x2"
            case .appearance: "paintpalette"
            case .displays: "display"
            case .startup: "power"
            }
        }
        var tint: Color {
            switch self {
            case .modules: Color(red: 0.37, green: 0.36, blue: 0.9)   // #5E5CE6
            case .appearance: Color(red: 1, green: 0.22, blue: 0.37)  // #FF375F
            case .displays: Color(red: 0.04, green: 0.52, blue: 1)    // #0A84FF
            case .startup: Color(red: 0.19, green: 0.71, blue: 0.4)   // #30B566
            }
        }
    }

    @State var pane: Pane = .modules

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(pane.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
            .safeAreaInset(edge: .bottom) {
                Text("Settings stay on this Mac")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
        } detail: {
            Form {
                switch pane {
                case .modules: ModulesPane()
                case .appearance: AppearancePane(store: .shared)
                case .displays: DisplaysSettings()
                case .startup: StartupPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.rawValue)
        }
        .frame(minWidth: 760, minHeight: 540)
    }
}

/// Modules, their order, and each module's own settings.
private struct ModulesPane: View {
    @AppStorage(SettingsKeys.showDemoSource) private var showDemoSource = false

    var body: some View {
        if let modules = AppModules.modules {
            ModulesSettings(modules: modules)
        }
        if let calendar = AppModules.calendar {
            CalendarSettings(module: calendar)
        }
        if let clipboard = AppModules.clipboard {
            ClipboardSettings(module: clipboard)
        }
        if let library = AppModules.library {
            Section("Screenshots") {
                Toggle("Add new macOS screenshots to the library", isOn: Binding(
                    get: { library.addsSystemScreenshots }, set: { library.setAddsSystemScreenshots($0) }))
                Text("Screenshots taken with ⇧⌘3, ⇧⌘4 or ⇧⌘5 from now on are copied in; the originals stay in \(ScreenshotWatcher.folder.lastPathComponent). macOS asks once for access to that folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Toggle("Show the Demo media source", isOn: $showDemoSource)
            Text("Spotify and Music are read through their public notifications and controlled with Apple Events after you allow it. Calendar events are read from the Calendar app on this Mac. Clipboard history stays on this Mac. No analytics; the only network use is loading cover art from the music services.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Open at login, what happens at launch, the menu bar icon and the global shortcut (M4.4).
private struct StartupPane: View {
    @AppStorage(StartupSettings.Keys.launch) private var launch = StartupSettings.Launch.quiet.rawValue
    @AppStorage(StartupSettings.Keys.menuBarIcon) private var menuBarIcon = true
    @State private var login = LoginItem.status
    @State private var loginError: String?
    private let amber = Color(red: 1, green: 0.72, blue: 0.3)

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { login != .off }, set: setLogin)) {
                Text("Open Orilio at login")
                Text(loginNote).foregroundStyle(login == .requiresApproval ? amber : .secondary)
            }
            if login == .requiresApproval {
                Button("Approve in System Settings…") { LoginItem.openSystemSettings() }
            }
            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(amber)
            }
        }
        Section("When Orilio starts") {
            Picker("When Orilio starts", selection: $launch) {
                ForEach(StartupSettings.Launch.allCases) { mode in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mode.title)
                        Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        Section {
            Toggle(isOn: $menuBarIcon) {
                Text("Menu bar icon")
                Text(menuBarIcon ? "Quick access to Settings and Quit" : "Hidden. Open Orilio again from Applications to get back here.")
                    .foregroundStyle(menuBarIcon ? .secondary : amber)
            }
            LabeledContent {
                if GlobalHotKey.isRegistered {
                    HStack(spacing: 4) {
                        ForEach(GlobalHotKey.display, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Control Option Space")
                } else {
                    Text("Shortcut unavailable").foregroundStyle(amber)
                }
            } label: {
                Text("Toggle the island")
                Text("Global shortcut, works in any app").foregroundStyle(.secondary)
            }
        }
        // The user can remove Orilio in System Settings at any time: read the real status each time.
        .onAppear { login = LoginItem.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login = LoginItem.status
        }
    }

    private var loginNote: String {
        switch login {
        case .enabled: "Registered with macOS · listed in System Settings › General › Login Items"
        case .requiresApproval: "Waiting for your approval in System Settings › General › Login Items"
        case .off: "Orilio starts only when you open it."
        }
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            try LoginItem.set(on)
        } catch {
            loginError = error.localizedDescription // the switch goes back to the real status below
        }
        login = LoginItem.status
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

/// Which modules the island shows and in which order, the one it opens to, and what the
/// collapsed island may show.
private struct ModulesSettings: View {
    let modules: ModuleSettings

    var body: some View {
        Section {
            ForEach(modules.order) { tab in
                ModuleRow(tab: tab, modules: modules)
            }
            .onMove { modules.move(from: $0, to: $1) }
        } header: {
            Text("Modules and order")
        } footer: {
            Text(modules.visible.count == 1
                 ? "One module always stays visible."
                 : "Order is the tab order in the island. Hidden modules never take the notch; hiding one turns it off (Calendar stops reading, Clipboard pauses, a focus session ends) without deleting anything.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Section {
            Picker("When the island opens, show", selection: Binding(get: { modules.openWith }, set: { modules.setOpenWith($0) })) {
                ForEach(Preferences.OpenWith.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section("Collapsed island") {
            ForEach(CollapsedIndicator.allCases) { indicator in
                Toggle(indicator.title, isOn: Binding(get: { modules.indicators.contains(indicator) },
                                                      set: { modules.setIndicator(indicator, $0) }))
            }
            Text("Only one shows at a time: a meeting about to start first, then a focus session, then music.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The design's module row: drag handle, icon, name and what it uses, up/down, visibility switch.
private struct ModuleRow: View {
    let tab: IslandTab
    let modules: ModuleSettings

    var body: some View {
        let visible = modules.isVisible(tab)
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.settingsTitle)
                Text(tab.settingsDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { modules.move(tab, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(modules.order.first == tab)
                .accessibilityLabel("Move \(tab.settingsTitle) up")
            Button { modules.move(tab, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(modules.order.last == tab)
                .accessibilityLabel("Move \(tab.settingsTitle) down")
            Toggle("Show \(tab.settingsTitle)", isOn: Binding(get: { visible }, set: { modules.setVisible(tab, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(visible && modules.visible.count == 1)
                .help(visible && modules.visible.count == 1 ? "One module always stays visible" : "")
        }
        .buttonStyle(.borderless)
        .opacity(visible ? 1 : 0.55)
    }
}

extension IslandTab {
    /// The names and notes of the M4 Settings design.
    var settingsTitle: String {
        switch self {
        case .calendar: "Calendar & Meetings"
        case .clipboard: "Clipboard History"
        case .notes: "Notes & Tasks"
        case .focus: "Focus & Pomodoro"
        case .music: "Now Playing"
        case .shelf: "Shelf & Screenshots"
        }
    }

    var settingsDetail: String {
        switch self {
        case .calendar: "Calendar access · iCloud, Google, Outlook"
        case .clipboard: "Text, links, images · local only"
        case .notes: "Stored on this Mac"
        case .focus: "No permission needed"
        case .music: "Spotify, Music · Automation"
        case .shelf: "Files you drop · ⌘⇧4 captures"
        }
    }
}

/// Which displays show the island, and how it behaves over fullscreen apps and Spaces.
private struct DisplaysSettings: View {
    @AppStorage(DisplaySettings.Keys.placement) private var placement = DisplaySettings().placement.rawValue
    @AppStorage(DisplaySettings.Keys.fullscreen) private var fullscreen = DisplaySettings().fullscreen.rawValue
    @AppStorage(DisplaySettings.Keys.allSpaces) private var allSpaces = true
    @AppStorage(DisplaySettings.Keys.externalWhenLidClosed) private var external = true
    @AppStorage(SettingsKeys.openOnHover) private var openOnHover = true

    var body: some View {
        Section("Displays") {
            Picker("Show the island on", selection: $placement) {
                ForEach(DisplaySettings.Placement.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("In fullscreen apps", selection: $fullscreen) {
                ForEach(DisplaySettings.Fullscreen.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Open the island on hover", isOn: $openOnHover)
            Toggle("Show on every Space and alongside Stage Manager", isOn: $allSpaces)
            Toggle("Move to the main external display when the lid is closed", isOn: $external)
                .disabled(placement != DisplaySettings.Placement.builtIn.rawValue)
            Text("Over a fullscreen app, a meeting starting now always shows. Displays without a notch get the floating pill.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Panel size, theme, accent and motion (M4.2). Every choice applies to the island at once.
private struct AppearancePane: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        let theme = Theme.resolve(store.value, systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        Section("Panel size") {
            Picker("Panel size", selection: $store.value.panelSize) {
                ForEach(Preferences.PanelSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            PanelPreview(size: store.value.panelSize, theme: theme)
        }
        Section("Theme") {
            HStack(spacing: 12) {
                ForEach(Preferences.ThemeStyle.allCases) { style in
                    ThemeCard(style: style, accent: store.value.accent.color, selected: store.value.theme == style) {
                        store.value.theme = style
                    }
                }
            }
            LabeledContent("Neon accent") {
                HStack(spacing: 10) {
                    ForEach(Preferences.Accent.allCases) { accent in
                        Button { store.value.accent = accent } label: {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().strokeBorder(store.value.accent == accent ? accent.color : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(accent.title)
                        .accessibilityLabel(accent.title)
                        .accessibilityAddTraits(store.value.accent == accent ? .isSelected : [])
                    }
                }
            }
        }
        Section("Animation") {
            Picker("Animation", selection: $store.value.motion) {
                ForEach(Preferences.Motion.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Follow system Reduce Motion", isOn: $store.value.followReduceMotion)
            if theme.motion != store.value.motion {
                Text("Reduce Motion is on in System Settings, so the island doesn't animate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A small open island at the chosen size, in the chosen theme (the design's live preview).
private struct PanelPreview: View {
    let size: Preferences.PanelSize
    let theme: Theme

    var body: some View {
        // The design draws 560 / 700 / 820 pt as 300 / 360 / 420 pt.
        let width = 300 + (size.width - 560) / 260 * 120
        let height = 92 + (size.width - 560) / 260 * 24
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.08, green: 0.11, blue: 0.18))
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                .fill(.black)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.32, blue: 0.39), Color(red: 0.07, green: 0.13, blue: 0.17)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(.white.opacity(0.8)).frame(width: 90, height: 6)
                            Capsule().fill(.white.opacity(0.16)).frame(height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(theme.color(.live)).frame(width: 70, height: 4)
                                        .shadow(color: theme.color(.live).opacity(0.7 * theme.glow(.live)), radius: 4)
                                }
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
                }
                .frame(width: width, height: height)
                .animation(theme.spring(duration: 0.44, bounce: 0.2), value: size)
            Text("\(size.title) · \(Int(size.width)) pt open")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)
        }
        .frame(height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(size.title) panel, \(Int(size.width)) points wide")
    }
}

/// One theme choice: a tiny collapsed island in that theme, its name and what it means.
private struct ThemeCard: View {
    let style: Preferences.ThemeStyle
    let accent: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let theme = Theme(style: style, accent: accent, motion: .spring)
        let chip = style == .calm ? Color.white : accent
        let wave = style == .neon ? accent : Color(red: 0.969, green: 0.71, blue: 0.431) // the artwork tint
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chip).frame(width: 22, height: 22)
                        .shadow(color: accent.opacity(0.7 * theme.glow(.live)), radius: 5)
                    Spacer()
                    HStack(spacing: 2.5) {
                        ForEach([8.0, 14, 10], id: \.self) { h in
                            Capsule().fill(wave).frame(width: 3, height: h)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title).font(.system(size: 13.5, weight: .semibold))
                    Text(style.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? accent : .white.opacity(0.08), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
