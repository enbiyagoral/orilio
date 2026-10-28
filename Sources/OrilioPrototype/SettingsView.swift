import AppKit
import SwiftUI

// The M4 Settings design ("M4.2–M4.4 — Settings (interactive)"), value for value: a 1040 × 760
// window (radius 16, #1C1C1F) with a 230 pt sidebar, a 52 pt title bar per pane and 24/28 padding.
enum SettingsDesign {
    static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: alpha)
    }

    static let window = hex(0x1C1C1F)
    static let sidebar = Color(red: 40 / 255, green: 40 / 255, blue: 45 / 255, opacity: 0.92)
    static let divider = Color.white.opacity(0.06)
    static let mint = hex(0x2BFFB8)
    static let loginOn = hex(0x7DFFD6)
    static let amber = hex(0xFFB86B)
    static let card = Color.white.opacity(0.04)
    static let cardStroke = Color.white.opacity(0.07)
    static let rowLine = Color.white.opacity(0.05)
    static let label = Color.white.opacity(0.85)
    static let secondary = Color.white.opacity(0.5)
    static let artTint = hex(0xF7B56E)
}

/// The design's placeholder artwork: a sun (#FFE2B0) and an ember (#E07A4F) over a dusk gradient.
struct DesignArtwork: View {
    var radius: CGFloat

    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [SettingsDesign.hex(0x2E5163), SettingsDesign.hex(0x12222C)],
                               startPoint: UnitPoint(x: 0.25, y: 0.07), endPoint: UnitPoint(x: 0.75, y: 0.93))
                Circle().fill(SettingsDesign.hex(0xE07A4F)).frame(width: s * 0.6, height: s * 0.6).position(x: s * 0.7, y: s * 0.78)
                Circle().fill(SettingsDesign.hex(0xFFE2B0)).frame(width: s * 0.32, height: s * 0.32).position(x: s * 0.32, y: s * 0.34)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private typealias Design = SettingsDesign

/// The Settings window: a sidebar of panes.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case modules, appearance, displays, startup
        var id: Self { self }
        var label: String {
            switch self {
            case .modules: "Modules"
            case .appearance: "Appearance"
            case .displays: "Displays"
            case .startup: "Startup"
            }
        }
        var title: String { self == .displays ? "Displays & Fullscreen" : label }
        var code: String {
            switch self {
            case .modules, .appearance: "M4.2"
            case .displays: "M4.3"
            case .startup: "M4.4"
            }
        }
        var symbol: String {
            switch self {
            case .modules: "square.grid.2x2"
            case .appearance: "circle.lefthalf.filled"
            case .displays: "display"
            case .startup: "power"
            }
        }
        var tile: Color {
            switch self {
            case .modules: Design.hex(0x5E5CE6)
            case .appearance: Design.hex(0xFF375F)
            case .displays: Design.hex(0x0A84FF)
            case .startup: Design.hex(0x30B566)
            }
        }
    }

    @State var pane: Pane = .modules
    /// False only for drawing a pane to an image (`ImageRenderer` doesn't draw scroll views).
    var scrolls = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Design.divider).frame(width: 1)
            VStack(spacing: 0) {
                Text(pane.title)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .frame(height: 52)
                Rectangle().fill(Design.divider).frame(height: 1)
                if scrolls {
                    ScrollView { content }
                } else {
                    content.frame(maxHeight: .infinity, alignment: .top).clipped()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .background(Design.window)
        .environment(\.colorScheme, .dark)
        .frame(width: 1040, height: 760)
        .ignoresSafeArea() // the content runs under the transparent title bar, as in the design
    }

    private var content: some View {
        Group {
            switch pane {
            case .modules: ModulesPane()
            case .appearance: AppearancePane(store: .shared)
            case .displays: DisplaysPane()
            case .startup: StartupPane()
            }
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The window's own traffic lights sit here (the design's 12 pt dots, 22 pt below them).
            Color.clear.frame(height: 36)
            ForEach(Pane.allCases) { item in
                Button { pane = item } label: {
                    HStack(spacing: 10) {
                        Group {
                            if item == .appearance {
                                AppearanceGlyph().stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                            .background(item.tile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(item.label).font(.system(size: 13.5, weight: .medium))
                        Spacer(minLength: 0)
                        Text(item.code).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(pane == item ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled() // the design has no focus ring; the selection shows the pane
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
            Text("Orilio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · settings stay on this Mac")
                .font(.system(size: 11.5))
                .lineSpacing(11.5 * 0.45)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(Design.sidebar)
    }
}

/// The design's Appearance icon (Lucide geometry on a 24-unit grid): a circle split by an S curve.
private struct AppearanceGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        // M12 2 a10 10 0 1 0 0 20 a4 4 0 0 1 0 -8 a4 4 0 0 0 0 -8: the left half of the circle, then an
        // S back up the middle (SwiftUI's `clockwise` is mirrored on screen, y pointing down).
        path.addArc(center: p(12, 12), radius: 10 * k, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        path.addArc(center: p(12, 18), radius: 4 * k, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.addArc(center: p(12, 10), radius: 4 * k, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        // M12 2 a10 10 0 0 1 0 20
        path.move(to: p(12, 2))
        path.addArc(center: p(12, 12), radius: 10 * k, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        return path
    }
}

// MARK: - The design's controls

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Design.label) }
}

/// Rows in a rounded card (radius 14, 4% white, a 7% hairline), separated by 5% lines.
struct SettingsCard<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Design.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Design.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private typealias Card = SettingsCard

private struct RowLine: View {
    var body: some View { Rectangle().fill(Design.rowLine).frame(height: 1) }
}

/// The design's switch: a mint track (20% white when off) with a white knob.
struct DesignSwitch: View {
    let isOn: Bool
    var large = false
    var label: String
    let action: () -> Void

    var body: some View {
        let width: CGFloat = large ? 44 : 40, height: CGFloat = large ? 26 : 24, knob: CGFloat = large ? 22 : 20
        Button(action: action) {
            Capsule()
                .fill(isOn ? Design.mint : Color.white.opacity(0.2))
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .offset(x: isOn ? width - knob - 2 : 2)
                }
                .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The design's segmented control: a 7% plate, the chosen segment white with black text.
private struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value
    let pick: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                let active = value == selection
                Button { pick(value) } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(active ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(active ? Color.white.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The design's checkbox: 15 pt, mint when on.
private struct DesignCheckbox: View {
    let title: String
    let isOn: Bool
    var size: CGFloat = 13
    var color: Color = .white.opacity(0.8)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(isOn ? Design.mint : Color.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.white.opacity(isOn ? 0 : 0.3), lineWidth: 1))
                    .overlay {
                        if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black) }
                    }
                    .frame(width: 15, height: 15)
                Text(title).font(.system(size: size)).foregroundStyle(color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The selection ring of the design's cards: 1.5 pt mint with a soft glow, else a 1 pt hairline.
private extension View {
    func selectionRing(_ selected: Bool, radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(selected ? Design.mint : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .shadow(color: selected ? Design.mint.opacity(0.18) : .clear, radius: 9)
    }
}

/// A plain text button in the design's style (for actions the design doesn't draw).
private struct DesignButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A row of a settings card: title and note on the left, a control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = Design.secondary
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(noteColor).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 54)
    }
}

// MARK: - Modules (M4.2)

private struct ModulesPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let modules = AppModules.modules {
                ModuleList(modules: modules)
                HStack(spacing: 20) {
                    SectionLabel("When the island opens, show")
                    Spacer()
                    Segmented(options: Preferences.OpenWith.allCases.map { ($0, $0.title) },
                              selection: modules.openWith) { modules.setOpenWith($0) }
                }
                CollapsedIndicators(modules: modules)
            }
            ModuleDetails()
        }
    }
}

private struct ModuleList: View {
    let modules: ModuleSettings
    @State private var dragging: IslandTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Modules and order")
                Spacer()
                Text(modules.visible.count == 1 ? "One module always stays visible."
                     : "Order = tab order in the island. Hidden modules never take the notch.")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.secondary)
            }
            Card {
                ForEach(Array(modules.order.enumerated()), id: \.element) { index, tab in
                    ModuleRow(tab: tab, index: index, modules: modules)
                        .onDrag {
                            dragging = tab
                            return NSItemProvider(object: tab.key as NSString)
                        }
                        .onDrop(of: [.text], delegate: ReorderDrop(target: tab, dragging: $dragging, modules: modules))
                    if index < modules.order.count - 1 { RowLine() }
                }
            }
        }
    }
}

/// Drag to reorder: the dragged module takes the place of the one it passes over.
private struct ReorderDrop: DropDelegate {
    let target: IslandTab
    @Binding var dragging: IslandTab?
    let modules: ModuleSettings

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = modules.order.firstIndex(of: dragging), let to = modules.order.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            modules.move(from: [from], to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct ModuleRow: View {
    let tab: IslandTab
    let index: Int
    let modules: ModuleSettings

    var body: some View {
        let visible = modules.isVisible(tab)
        let last = modules.order.count - 1
        HStack(spacing: 12) {
            Grip()
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.settingsTitle).font(.system(size: 14, weight: .medium))
                Text(tab.settingsDetail).font(.system(size: 12)).foregroundStyle(Design.secondary)
            }
            Spacer(minLength: 0)
            ArrowButton(symbol: "chevron.up", label: "Move \(tab.settingsTitle) up", enabled: index > 0) { modules.move(tab, by: -1) }
            ArrowButton(symbol: "chevron.down", label: "Move \(tab.settingsTitle) down", enabled: index < last) { modules.move(tab, by: 1) }
            DesignSwitch(isOn: visible, label: "Show \(tab.settingsTitle)") {
                modules.setVisible(tab, !visible) // the last visible module can't be hidden
            }
            .help(visible && modules.visible.count == 1 ? "One module always stays visible" : "")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 56)
        .opacity(visible ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}

/// The design's six-dot drag handle.
private struct Grip: View {
    var body: some View {
        Canvas { context, _ in
            for x in [3.0, 9.0] { for y in [2.0, 6.0, 10.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.35)))
            } }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private struct ArrowButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Which live states the collapsed island may show (beyond the design, in its style).
private struct CollapsedIndicators: View {
    let modules: ModuleSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Collapsed island")
                Spacer()
                Text("One at a time: a meeting first, then focus, then music.").font(.system(size: 12)).foregroundStyle(Design.secondary)
            }
            Card {
                ForEach(Array(CollapsedIndicator.allCases.enumerated()), id: \.element) { index, indicator in
                    let on = modules.indicators.contains(indicator)
                    SettingRow(title: indicator.title) {
                        DesignSwitch(isOn: on, label: indicator.title) { modules.setIndicator(indicator, !on) }
                    }
                    if index < CollapsedIndicator.allCases.count - 1 { RowLine() }
                }
            }
        }
    }
}

/// Each module's own settings (beyond the design, in its style).
private struct ModuleDetails: View {
    @AppStorage(SettingsKeys.showDemoSource) private var showDemoSource = false
    @AppStorage(SettingsKeys.openOnHover) private var openOnHover = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Island")
                Card {
                    SettingRow(title: "Open the island on hover", note: "Otherwise it opens when you click it.") {
                        DesignSwitch(isOn: openOnHover, label: "Open the island on hover") { openOnHover.toggle() }
                    }
                }
            }
            if let calendar = AppModules.calendar { CalendarSettings(module: calendar) }
            if let clipboard = AppModules.clipboard { ClipboardSettings(module: clipboard) }
            if let library = AppModules.library {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Screenshots")
                    Card {
                        SettingRow(title: "Add new macOS screenshots to the library",
                                   note: "From ⇧⌘3, ⇧⌘4 or ⇧⌘5, from now on; the originals stay in \(ScreenshotWatcher.folder.lastPathComponent). macOS asks once for access to that folder.") {
                            DesignSwitch(isOn: library.addsSystemScreenshots, label: "Add new macOS screenshots") {
                                library.setAddsSystemScreenshots(!library.addsSystemScreenshots)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Privacy")
                Card {
                    SettingRow(title: "Show the Demo media source", note: "A labelled fake player for trying the island; plays nothing.") {
                        DesignSwitch(isOn: showDemoSource, label: "Show the Demo media source") { showDemoSource.toggle() }
                    }
                    RowLine()
                    Text("Spotify and Music are read through their public notifications and controlled with Apple Events after you allow it. Calendar events are read from the Calendar app on this Mac. Clipboard history stays on this Mac. No analytics; the only network use is loading cover art from the music services.")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Calendar on/off, which calendars to show, and meeting reminders. Turning Calendar on is the
/// only thing that asks for calendar access; choosing a reminder is the only thing that asks to
/// send notifications.
private struct CalendarSettings: View {
    let module: CalendarModule

    var body: some View {
        let on = module.status != .off
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Calendar")
            Card {
                SettingRow(title: "Show today's events and meetings") {
                    DesignSwitch(isOn: on, label: "Show today's events and meetings") {
                        if on { module.disable() } else { Task { await module.enable() } }
                    }
                }
                if on {
                    if module.status == .denied {
                        RowLine()
                        SettingRow(title: "Access", note: "Allow Orilio in Privacy & Security › Calendars.", noteColor: Design.amber) {
                            DesignButton(title: "Open System Settings…") { NSWorkspace.shared.open(CalendarModule.privacySettingsURL) }
                        }
                    } else if module.status == .restricted {
                        RowLine()
                        SettingRow(title: "Access", note: "Calendar access is restricted on this Mac.", noteColor: Design.amber) { EmptyView() }
                    }
                    RowLine()
                    SettingRow(title: "Meeting reminders") {
                        Segmented(options: [(-1, "Off"), (0, "At start"), (5, "5 min"), (10, "10 min")],
                                  selection: module.reminderLeadMinutes) { lead in Task { await module.setReminderLead(lead) } }
                    }
                    ForEach(module.calendars) { calendar in
                        RowLine()
                        let visible = !module.hiddenCalendarIDs.contains(calendar.id)
                        HStack(spacing: 8) {
                            Circle().fill(calendar.color.color).frame(width: 9, height: 9)
                            Text(calendar.title).font(.system(size: 13.5, weight: .medium))
                            Text(calendar.sourceTitle).font(.system(size: 12)).foregroundStyle(Design.secondary)
                            Spacer()
                            DesignSwitch(isOn: visible, label: calendar.title) { module.setCalendar(calendar.id, visible: !visible) }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                    }
                }
            }
        }
    }
}

/// Clipboard history on/off, pause, limits. Turning it off deletes the stored history.
private struct ClipboardSettings: View {
    let module: ClipboardModule

    var body: some View {
        let on = module.status != .off
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Clipboard")
            Card {
                SettingRow(title: "Keep a clipboard history", note: "Turning it off deletes the history. Items apps mark private, and copies made while a password manager is in front, are never recorded.") {
                    DesignSwitch(isOn: on, label: "Keep a clipboard history") {
                        Task { on ? await module.disable() : await module.enable() }
                    }
                }
                if module.status == .blocked {
                    RowLine()
                    SettingRow(title: "Access", note: "macOS denies Orilio reading other apps' copies.", noteColor: Design.amber) {
                        DesignButton(title: "Open System Settings…") { NSWorkspace.shared.open(ClipboardModule.pasteSettingsURL) }
                    }
                } else if on {
                    RowLine()
                    SettingRow(title: "Pause recording") {
                        DesignSwitch(isOn: module.status == .paused, label: "Pause recording") {
                            module.status == .paused ? module.resume() : module.pause()
                        }
                    }
                    RowLine()
                    SettingRow(title: "Keep items for") {
                        Segmented(options: [(1, "1 day"), (7, "7 days"), (30, "30 days"), (0, "Until removed")],
                                  selection: module.retentionDays) { module.setRetention(days: $0) }
                    }
                    RowLine()
                    SettingRow(title: "Keep at most") {
                        Segmented(options: [(50, "50"), (200, "200"), (500, "500")], selection: module.maxItems) { module.setMaxItems($0) }
                    }
                    RowLine()
                    SettingRow(title: "History") {
                        DesignButton(title: "Clear Unpinned Items") { module.clear() }
                    }
                }
            }
        }
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
        case .mirror: "Camera Mirror"
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
        case .mirror: "Camera · only while open"
        }
    }
}

// MARK: - Appearance (M4.2)

private struct AppearancePane: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        let p = store.value
        let accent = p.accent.color
        let calm = p.theme == .calm
        let systemReduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Panel size")
                    Spacer()
                    Segmented(options: Preferences.PanelSize.allCases.map { ($0, $0.title) }, selection: p.panelSize) { store.value.panelSize = $0 }
                }
                PanelPreview(size: p.panelSize, accent: accent, calm: calm, motion: p.motion)
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Theme")
                HStack(spacing: 12) {
                    ForEach(Preferences.ThemeStyle.allCases) { style in
                        ThemeCard(style: style, accent: accent, selected: p.theme == style) { store.value.theme = style }
                    }
                }
                HStack {
                    Text("Neon accent").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(Preferences.Accent.allCases) { option in
                            let active = p.accent == option
                            Button { store.value.accent = option } label: {
                                Circle().fill(option.color).frame(width: 28, height: 28)
                                    // The design's ring: 2 pt of the window color, then 2 pt of the accent, and a glow.
                                    .overlay(Circle().strokeBorder(active ? option.color : .clear, lineWidth: 2).padding(-4))
                                    .shadow(color: active ? option.color.opacity(0.6) : .clear, radius: 7)
                            }
                            .buttonStyle(.plain)
                            .help(option.title)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Animation")
                    DesignCheckbox(title: "Follow system Reduce Motion", isOn: p.followReduceMotion, size: 12.5,
                                   color: .white.opacity(0.6)) { store.value.followReduceMotion.toggle() }
                        .padding(.top, 4)
                    if p.followReduceMotion && systemReduce {
                        Text("Reduce Motion is on in System Settings, so the island doesn't animate.")
                            .font(.system(size: 12)).foregroundStyle(Design.secondary).padding(.top, 2)
                    }
                }
                Spacer()
                Segmented(options: Preferences.Motion.allCases.map { ($0, $0.title) }, selection: p.motion) { store.value.motion = $0 }
            }
        }
    }
}

/// The design's live preview: an open island at the chosen size, in the chosen theme.
private struct PanelPreview: View {
    let size: Preferences.PanelSize
    let accent: Color
    let calm: Bool
    let motion: Preferences.Motion

    var body: some View {
        let (width, height): (CGFloat, CGFloat) = switch size {
        case .compact: (300, 92)
        case .standard: (360, 104)
        case .large: (420, 116)
        }
        let glow = calm ? Design.artTint.opacity(0.18) : accent.opacity(0.28)
        let bar = calm ? Color.white : accent
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
        ZStack(alignment: .top) {
            Rectangle().fill(Design.hex(0x141B2D))
            EllipticalGradient(colors: [Design.hex(0x2F6E6C), Design.hex(0x2F6E6C, 0)], center: UnitPoint(x: 0.1, y: 1),
                               startRadiusFraction: 0, endRadiusFraction: 0.7)
            ZStack(alignment: .bottomLeading) {
                shape.fill(.black)
                EllipticalGradient(colors: [glow, .clear], center: UnitPoint(x: 0.15, y: 0.7), startRadiusFraction: 0, endRadiusFraction: 0.7)
                    .clipShape(shape)
                HStack(alignment: .bottom, spacing: 10) {
                    DesignArtwork(radius: 9).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.8)).frame(width: g.size.width * 0.5, height: 6)
                        }
                        .frame(height: 6)
                        Capsule().fill(.white.opacity(0.16)).frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(bar).frame(width: g.size.width * 0.4, height: 4)
                                        .shadow(color: calm ? .clear : accent.opacity(0.7), radius: 4)
                                }
                            }
                    }
                    .padding(.bottom, 4)
                }
                .padding(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
            }
            .frame(width: width, height: height)
            .animation(animation, value: size)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note)
    }

    private var note: String { "\(size.title) · \(Int(size.width)) pt open" }

    private var animation: Animation? {
        switch motion {
        case .spring: .spring(duration: 0.44, bounce: 0.25)
        case .subtle: .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.44)
        case .off: nil
        }
    }
}

/// One theme choice: a tiny collapsed island in that theme, its name and what it means.
private struct ThemeCard: View {
    let style: Preferences.ThemeStyle
    let accent: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let chip: Color = style == .calm ? .white : accent
        let wave: Color = style == .neon ? accent : Design.artTint
        let glow: Color = style == .calm ? .clear : accent.opacity(0.7)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chip).frame(width: 22, height: 22)
                        .shadow(color: glow, radius: 5)
                    Spacer()
                    HStack(spacing: 2.5) {
                        ForEach(Array([8.0, 14, 10].enumerated()), id: \.offset) { _, h in
                            RoundedRectangle(cornerRadius: 2).fill(wave).frame(width: 3, height: h).shadow(color: glow, radius: 5)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title).font(.system(size: 13.5, weight: .semibold))
                    Text(style.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .selectionRing(selected, radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Displays (M4.3)

private struct DisplaysPane: View {
    @AppStorage(DisplaySettings.Keys.placement) private var placement = DisplaySettings().placement.rawValue
    @AppStorage(DisplaySettings.Keys.fullscreen) private var fullscreen = DisplaySettings().fullscreen.rawValue
    @AppStorage(DisplaySettings.Keys.allSpaces) private var allSpaces = true
    @AppStorage(DisplaySettings.Keys.externalWhenLidClosed) private var external = true

    var body: some View {
        let showOn = DisplaySettings.Placement(rawValue: placement) ?? .pointer
        let prefs = PreferencesStore.shared.value
        VStack(alignment: .leading, spacing: 22) {
            DisplaysIllustration(showOn: showOn, glow: prefs.theme == .calm ? Design.artTint.opacity(0.18) : prefs.accent.color.opacity(0.28))
            HStack {
                SectionLabel("Show the island on")
                Spacer()
                Segmented(options: [(DisplaySettings.Placement.builtIn, "Built-in only"), (.all, "All displays"), (.pointer, "Display with pointer")],
                          selection: showOn) { placement = $0.rawValue }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("In fullscreen apps")
                HStack(alignment: .top, spacing: 10) {
                    ForEach([(DisplaySettings.Fullscreen.hide, "Hide", "Stays out of the way. Live activities wait until you leave fullscreen."),
                             (.reveal, "Reveal from top edge", "Push the pointer to the top to bring the island back."),
                             (.show, "Always show", "The island floats over fullscreen apps.")], id: \.0) { mode, label, detail in
                        let active = fullscreen == mode.rawValue
                        Button { fullscreen = mode.rawValue } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(label).font(.system(size: 13.5, weight: .semibold))
                                Text(detail).font(.system(size: 12)).lineSpacing(12 * 0.4).foregroundStyle(.white.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Design.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .selectionRing(active, radius: 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                DesignCheckbox(title: "Show on every Space and alongside Stage Manager", isOn: allSpaces) { allSpaces.toggle() }
                DesignCheckbox(title: "Move to the main external display when the lid is closed", isOn: external) { external.toggle() }
            }
        }
    }
}

/// The design's two displays: the MacBook with its notch, and an external display with the pill.
private struct DisplaysIllustration: View {
    let showOn: DisplaySettings.Placement
    let glow: Color

    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Design.hex(0x1D3B4A), Design.hex(0x3A2E50)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(.black).frame(width: 40, height: 7)
                    if showOn != .pointer {
                        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(.black).frame(width: 58, height: 7)
                            .shadow(color: glow, radius: 5)
                    }
                }
                .frame(width: 220, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Design.hex(0x2A2A2E)).padding(-5))
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(Design.hex(0x3A3A3F))
                    .frame(width: 250, height: 7)
                    .padding(.top, -3)
                Text("Built-in · notch").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .opacity(showOn == .pointer ? 0.55 : 1)

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Design.hex(0x22314A), Design.hex(0x4A3048)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if showOn != .builtIn {
                        Capsule().fill(.black).frame(width: 56, height: 8)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                            .shadow(color: glow, radius: 5)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 3)
                    }
                    if showOn == .pointer {
                        Image(systemName: "cursorarrow").font(.system(size: 15)).foregroundStyle(.white)
                            .shadow(color: .black, radius: 0.6)
                            .offset(x: 180, y: 70)
                    }
                }
                .frame(width: 300, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Design.hex(0x2A2A2E)).padding(-5))
                Rectangle().fill(Design.hex(0x2A2A2E)).frame(width: 60, height: 16).padding(.top, -3)
                Text("External · no notch → pill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .opacity(showOn == .builtIn ? 0.55 : 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Design.cardStroke, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The island is shown on: \(showOn.title)")
    }
}

// MARK: - Startup (M4.4)

private struct StartupPane: View {
    @AppStorage(StartupSettings.Keys.launch) private var launch = StartupSettings.Launch.quiet.rawValue
    @AppStorage(StartupSettings.Keys.menuBarIcon) private var menuBarIcon = true
    @State private var login = LoginItem.status
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Image(systemName: "power")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Design.mint)
                        .frame(width: 44, height: 44)
                        .background(Design.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open Orilio at login").font(.system(size: 15, weight: .semibold))
                        Text(loginNote).font(.system(size: 12.5)).foregroundStyle(loginNoteColor)
                    }
                    Spacer(minLength: 0)
                    DesignSwitch(isOn: login != .off, large: true, label: "Open Orilio at login") { setLogin(login == .off) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Design.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Design.cardStroke, lineWidth: 1))
                if login == .requiresApproval {
                    DesignButton(title: "Approve in System Settings…") { LoginItem.openSystemSettings() }
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Design.amber)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("When Orilio starts")
                Card {
                    ForEach(Array(StartupSettings.Launch.allCases.enumerated()), id: \.element) { index, mode in
                        let active = launch == mode.rawValue
                        Button { launch = mode.rawValue } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .strokeBorder(active ? Design.mint : Color.white.opacity(0.35), lineWidth: 1.5)
                                    .overlay(Circle().fill(active ? Design.mint : .clear).frame(width: 8, height: 8))
                                    .frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mode.title).font(.system(size: 13.5, weight: .medium))
                                    Text(mode.detail).font(.system(size: 12)).foregroundStyle(Design.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
                        if index < StartupSettings.Launch.allCases.count - 1 { RowLine() }
                    }
                }
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu bar icon").font(.system(size: 13.5, weight: .medium))
                    Text(menuBarIcon ? "Quick access to Settings, pin and Quit" : "Hidden. Open Orilio again from Applications to get back here.")
                        .font(.system(size: 12))
                        .foregroundStyle(menuBarIcon ? Design.secondary : Design.amber)
                }
                Spacer(minLength: 0)
                DesignSwitch(isOn: menuBarIcon, label: "Show menu bar icon") { menuBarIcon.toggle() }
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Onboarding").font(.system(size: 13.5, weight: .medium))
                    Text("The first-run tour in the island").font(.system(size: 12)).foregroundStyle(Design.secondary)
                }
                Spacer(minLength: 0)
                DesignButton(title: "Replay onboarding") {
                    OnboardingModel.reset()
                    AppModules.island?.startOnboarding()
                }
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toggle the island").font(.system(size: 13.5, weight: .medium))
                    Text("Global shortcut, works in any app").font(.system(size: 12)).foregroundStyle(Design.secondary)
                }
                Spacer(minLength: 0)
                if GlobalHotKey.isRegistered {
                    HStack(spacing: 4) {
                        ForEach(GlobalHotKey.display, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Control Option Space")
                } else {
                    Text("Shortcut unavailable").font(.system(size: 13, weight: .medium)).foregroundStyle(Design.amber)
                }
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

    private var loginNoteColor: Color {
        switch login {
        case .enabled: Design.loginOn
        case .requiresApproval: Design.amber
        case .off: .white.opacity(0.55)
        }
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            try LoginItem.set(on)
        } catch {
            loginError = error.localizedDescription // the switch shows the real status below
        }
        login = LoginItem.status
    }
}
