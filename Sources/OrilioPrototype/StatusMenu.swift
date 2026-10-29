// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation
import SwiftUI

private typealias Design = SettingsDesign

/// The four quick actions under the menu's header (the M5 System design).
enum QuickAction: String, CaseIterable, Identifiable {
    case pin, focus, note, mirror
    var id: Self { self }

    var label: String {
        switch self {
        case .pin: "Pin"
        case .focus: "Focus"
        case .note: "Note"
        case .mirror: "Mirror"
        }
    }

    var symbol: String {
        switch self {
        case .pin: "pin"
        case .focus: "timer"
        case .note: "pencil"
        case .mirror: "camera"
        }
    }

    /// The module behind the tile: hidden, the tile is gone.
    var module: IslandTab? {
        switch self {
        case .pin: nil
        case .focus: .focus
        case .note: .notes
        case .mirror: .mirror
        }
    }

    static func visible(hidden: Set<IslandTab>) -> [QuickAction] {
        allCases.filter { $0.module.map { !hidden.contains($0) } ?? true }
    }
}

/// The header's live line: what the collapsed island shows, in words. Pure.
enum MenuStatus {
    @MainActor static func line(layout: EarLayout, focus: FocusModule, now: Date) -> String? {
        switch layout.primary?.payload {
        case .meeting(let event)?:
            return MeetingEar.started(event, now: now) ? "\(event.title) · now"
                : String(localized: "\(event.title) \(CalendarDay.countdown(to: event.start, from: now))")
        case .focus(let kind)?:
            switch kind {
            case .running: return focus.isRunning ? String(localized: "Focus · \(FocusSession.text(focus.remaining(at: now))) left") : "Focus · paused"
            case .onBreak: return String(localized: "Break · \(FocusSession.text(focus.breakRemaining(at: now))) left")
            case .done(let label): return label
            }
        case .nowPlaying(let session)?:
            return [session.title, session.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .transient(let transient)?:
            return transient.title
        case .extensionEar(let content, _)?:
            return [content.leading, content.trailing].compactMap { part in
                guard let part else { return nil }
                if part.style == "countdown", let target = part.target { return ExtensionCountdown.text(to: target, from: now) }
                return part.text
            }.joined(separator: " · ")
        case nil:
            return nil
        }
    }
}

/// The menu bar extra: an `NSStatusItem` with a native `NSMenu`, so keyboard navigation and
/// VoiceOver behave like any other menu. The header and the quick actions are SwiftUI views
/// hosted in menu items; everything else is a standard item.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let toggleIsland: () -> Void
    private let open: (IslandTab) -> Void
    private var defaultsObserver: NSObjectProtocol?
    /// Ticks once a second only while the menu is open, for the header's live line.
    private var openTimer: Timer?
    private let header = MenuHeaderModel()

    init(toggleIsland: @escaping () -> Void, open: @escaping (IslandTab) -> Void) {
        self.toggleIsland = toggleIsland
        self.open = open
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        updateVisibility()
        // Settings › Startup › Menu bar icon.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        followUpdate()
    }

    private func updateVisibility() {
        let shown = StartupSettings.showsMenuBarIcon
        if shown, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            self.item = item
            updateIcon()
        } else if !shown, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// A mint dot on the icon while an update waits.
    private func followUpdate() {
        withObservationTracking { _ = UpdateModel.shared.waiting } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.followUpdate()
            }
        }
    }

    private func updateIcon() {
        item?.button?.image = MenuBarIcon.image(dot: UpdateModel.shared.waiting != nil)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        header.refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.header.refresh() } }
        RunLoop.main.add(timer, forMode: .common) // menus track events in their own run loop mode
        openTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        openTimer?.invalidate()
        openTimer = nil
    }

    private func rebuild() {
        menu.removeAllItems()
        let hidden = AppModules.modules?.hidden ?? []
        menu.addItem(hosted(MenuHeaderView(model: header), height: 56))
        let actions = QuickAction.visible(hidden: hidden)
        menu.addItem(hosted(QuickActionGrid(actions: actions) { [weak self] action in
            self?.menu.cancelTracking()
            self?.perform(action)
        }, height: 66))
        menu.addItem(.separator())

        let shortcut = PreferencesStore.shared.value.shortcut(.toggleIsland)
        let openItem = MenuAction("Open Island") { [weak self] in self?.toggleIsland() }
        if !shortcut.isNone {
            openItem.keyEquivalent = shortcut.key == "Space" ? " " : shortcut.key.lowercased()
            openItem.keyEquivalentModifierMask = Self.modifiers(shortcut.modifiers)
        }
        menu.addItem(openItem)
        let settings = MenuAction("Settings…") { SettingsWindow.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        if let update = UpdateModel.shared.waiting {
            let restart = MenuAction("Restart to Update") { UpdateModel.shared.install() }
            restart.badge = NSMenuItemBadge(string: update.version)
            menu.addItem(restart)
        }
        menu.addItem(MenuAction("Send Feedback…") { FeedbackWindow.show() })
        #if DEBUG
        menu.addItem(debugItem())
        #endif
        menu.addItem(.separator())
        menu.addItem(MenuAction("About Orilio") { SettingsWindow.show(pane: .about) })
        let quit = MenuAction("Quit Orilio") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func perform(_ action: QuickAction) {
        guard let island = AppModules.island else { return }
        switch action {
        case .pin: island.state == .pinned ? island.dismiss() : toggleIsland()
        case .focus: island.focus.toggle()
        case .note:
            island.notes.newNote()
            open(.notes)
        case .mirror: open(.mirror)
        }
    }

    private func hosted(_ view: some View, height: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        let host = NSHostingView(rootView: view.frame(width: 284, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        item.view = host
        return item
    }

    private static func modifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & 0x1000 != 0 { flags.insert(.control) } // controlKey
        if carbon & 0x0800 != 0 { flags.insert(.option) }  // optionKey
        if carbon & 0x0200 != 0 { flags.insert(.shift) }   // shiftKey
        if carbon & 0x0100 != 0 { flags.insert(.command) } // cmdKey
        return flags
    }

    #if DEBUG
    /// Shortcuts for checking things by hand. Debug builds only.
    private func debugItem() -> NSMenuItem {
        let debug = NSMenu()
        if let island = AppModules.island {
            debug.addItem(MenuAction(island.focus.isActive ? "Stop focus" : "Start focus") {
                island.focus.isActive ? island.focus.reset() : island.focus.begin()
            })
            debug.addItem(MenuAction("Start a 1-minute focus session") {
                island.focus.reset()
                island.focus.setMinutes(1)
                island.focus.begin()
            })
            let modules = NSMenu()
            for tab in IslandTab.allCases {
                modules.addItem(MenuAction("\(island.modules.isVisible(tab) ? "Hide" : "Show") \(tab.rawValue)") {
                    island.modules.setVisible(tab, !island.modules.isVisible(tab))
                })
            }
            let sub = NSMenuItem(title: L("Hide or show a module"), action: nil, keyEquivalent: "")
            sub.submenu = modules
            debug.addItem(sub)
        }
        let item = NSMenuItem(title: L("Debug"), action: nil, keyEquivalent: "")
        item.submenu = debug
        return item
    }
    #endif
}

/// The header's live line, refreshed while the menu is open.
@MainActor @Observable
final class MenuHeaderModel {
    private(set) var status: String?
    func refresh() {
        guard let island = AppModules.island else { return status = nil }
        let line = MenuStatus.line(layout: island.earLayout, focus: island.focus, now: Date())
        if line != status { status = line }
    }
}

/// The app mark, "Orilio" and what's live (mint).
struct MenuHeaderView: View {
    let model: MenuHeaderModel

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Design.hex(0x1B2233), Design.hex(0x07080C)], startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(.black).frame(width: 15, height: 5)
                        Capsule().fill(Design.mint).frame(width: 7, height: 2).shadow(color: Design.mint, radius: 2.5).padding(.top, 2)
                    }
                }
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Orilio").font(.system(size: 13, weight: .semibold))
                if let status = model.status {
                    Text(L(status)).font(.system(size: 11.5)).foregroundStyle(Design.loginOn).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
        .foregroundStyle(Design.ink)
        .accessibilityElement(children: .combine)
    }
}

/// Four 58 pt tiles (radius 11); an active one is mint.
struct QuickActionGrid: View {
    let actions: [QuickAction]
    let run: (QuickAction) -> Void

    private static let tile = Design.adaptive(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.05))
    private static let activeTile = Design.adaptive(dark: NSColor(srgbRed: 43 / 255, green: 1, blue: 184 / 255, alpha: 0.16),
                                                    light: NSColor(srgbRed: 19 / 255, green: 184 / 255, blue: 135 / 255, alpha: 0.14))

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                let active = isActive(action)
                Button { run(action) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: active && action == .pin ? "pin.fill" : action.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(active ? Design.accentText : Design.ink)
                        Text(L(action.label)).font(.system(size: 10.5)).foregroundStyle(Design.muted(0.75))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(active ? Self.activeTile : Self.tile, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L(action.label))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(EdgeInsets(top: 0, leading: 2, bottom: 8, trailing: 2))
    }

    private func isActive(_ action: QuickAction) -> Bool {
        guard let island = AppModules.island else { return false }
        switch action {
        case .pin: return island.state == .pinned
        case .focus: return island.focus.isRunning
        case .mirror: return island.state.isOpen && island.tab == .mirror
        case .note: return false
        }
    }
}
