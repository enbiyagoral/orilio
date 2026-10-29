// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import CoreLocation
import OrilioExtensionKit
import SwiftUI
import UserNotifications

// The Extensions window (the Extensions · ExtCatalog design): browse, install with consent, turn on
// or off, update and uninstall. Plus the settings form each extension's manifest describes.

/// The design's colors on dark; on light, the Settings window's (graphite buttons, darker mint).
private let mint = SettingsDesign.accent
private let mintText = SettingsDesign.accentText
private let buttonFill = SettingsDesign.primaryFill
private let buttonText = SettingsDesign.primaryText
private let ink = SettingsDesign.ink
/// The chosen chip: white with black text on dark, graphite with white text on light.
private let chosenText = SettingsDesign.adaptive(dark: .black, light: .white)
private func surface(_ dark: UInt32, light: UInt32) -> Color { SettingsDesign.adaptive(dark: SettingsDesign.ns(dark), light: SettingsDesign.ns(light)) }

/// The design's white at `opacity` on dark. On light: black tints for fills, Settings' greys for text.
private func fade(_ opacity: Double) -> Color {
    SettingsDesign.adaptive(dark: .white.withAlphaComponent(opacity),
                            light: opacity >= 0.3 ? SettingsDesign.ns(opacity >= 0.7 ? 0x3A3A3C : 0x6E6E73) : .black.withAlphaComponent(opacity * 0.9))
}
private let mono = Font.system(size: 11.5, design: .monospaced)

@MainActor
enum ExtensionsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: ExtensionsView(catalog: .shared, host: .shared))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = L("Orilio Extensions")
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? SettingsDesign.ns(0x17171B) : .white }
            window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 780), display: false)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        Task { await ExtensionCatalog.shared.load(force: true) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Asks for notifications once the user allowed an extension to send them.
func requestExtensionNotifications(_ permissions: ExtensionManifest.Permissions) async {
    guard permissions.notifications else { return }
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
}

private enum Selection: Hashable { case entry(String), build }

private enum Category: String, CaseIterable {
    case all, productivity, developer, lifestyle, finance
    var label: String { rawValue.capitalized }
}

struct ExtensionsView: View {
    let catalog: ExtensionCatalog
    let host: ExtensionHost

    @State private var category = Category.all
    @State private var query = ""
    @State private var selection: Selection?
    @State private var consent: CatalogEntry?
    @State private var settingsFor: SheetID?
    @State private var busy: String?
    @State private var failure: String?

    private var items: [CatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.entries.filter {
            (category == .all || $0.category == category.rawValue) && (q.isEmpty || "\($0.name) \($0.tagline)".lowercased().contains(q))
        }
    }

    private var categories: [Category] {
        let used = Set(catalog.entries.map(\.category))
        return Category.allCases.filter { $0 == .all || used.contains($0.rawValue) }
    }

    private var showsBuild: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || "build your own".contains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Orilio Extensions")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(surface(0x1F1F24, light: 0xF5F5F7))
                .overlay(alignment: .bottom) { Rectangle().fill(fade(0.06)).frame(height: 1) }
            HStack(spacing: 0) {
                browser
                Rectangle().fill(fade(0.06)).frame(width: 1)
                detail
                    .frame(width: 400)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(fade(0.02))
            }
        }
        .foregroundStyle(ink)
        .background(surface(0x17171B, light: 0xFFFFFF))
        .frame(width: 1280, height: 780)
        .ignoresSafeArea()
        .onAppear { if selection == nil { selection = catalog.entries.first.map { .entry($0.id) } ?? .build } }
        .onChange(of: catalog.entries) { if selection == nil { selection = catalog.entries.first.map { .entry($0.id) } } }
        .sheet(item: $settingsFor) { sheet in ExtensionSettingsView(id: sheet.id, host: host) { settingsFor = nil } }
    }

    // MARK: Browse

    private var browser: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make your notch yours.").font(.system(size: 32, weight: .semibold)).tracking(-0.96)
                    Text("Free, open-source extensions that live in the island — built by the community.")
                        .font(.system(size: 14)).foregroundStyle(fade(0.6))
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(fade(0.5))
                    TextField("", text: $query, prompt: Text("Search extensions").foregroundStyle(fade(0.4)))
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .accessibilityLabel("Search extensions")
                }
                .padding(.horizontal, 12)
                .frame(width: 260, height: 36)
                .background(fade(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            // Only categories something is in; with one (or none) there's nothing to filter.
            if categories.count > 2 {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { item in
                        let active = item == category
                        Button { category = item } label: {
                            Text(L(item.label))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(active ? chosenText : fade(0.8))
                                .padding(.horizontal, 14).frame(height: 30)
                                .background(active ? fade(0.9) : fade(0.07), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            if catalog.offline {
                StatusCard(tone: .warn, symbol: "wifi.slash", title: "Can’t reach the catalog",
                           detail: "Showing the extensions that come with Orilio. Check your connection and try again.",
                           primary: .init("Try again") { Task { await catalog.load(force: true) } }, layout: .banner)
            }
            if items.isEmpty && !showsBuild {
                StatusCard(tone: .empty, symbol: "magnifyingglass", title: "No extensions match",
                           detail: "Try another name, or pick All.", primary: .init("Clear search") { query = ""; category = .all })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14), count: 3), spacing: 14) {
                        ForEach(items) { entry in
                            card(tile: entry.tint, icon: ExtensionIcons.symbol(entry.icon) ?? "puzzlepiece.extension", name: entry.name,
                                 tagline: entry.tagline, chips: entry.permissions.chips,
                                 installed: host.installed.contains { $0.id == entry.id }, selected: selection == .entry(entry.id)) {
                                selection = .entry(entry.id)
                                consent = nil
                                failure = nil
                            }
                        }
                        if showsBuild {
                            card(tile: nil, icon: "chevron.left.forwardslash.chevron.right", name: "Build your own",
                                 tagline: "A manifest, a script, and Orilio does the rest", chips: ["Docs"], installed: false,
                                 selected: selection == .build) {
                                selection = .build
                                consent = nil
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func card(tile: String?, icon: String, name: String, tagline: String, chips: [String], installed: Bool,
                      selected: Bool, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Tile(tint: tile, icon: icon, size: 46, radius: 13)
                    Spacer()
                    if installed {
                        Text("Installed").font(.system(size: 11, weight: .semibold)).foregroundStyle(mintText)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(name)).font(.system(size: 15.5, weight: .semibold))
                    Text(L(tagline)).font(.system(size: 12.5)).lineSpacing(12.5 * 0.4 - 2).foregroundStyle(fade(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(L(chip)).font(.system(size: 11)).foregroundStyle(fade(0.7))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(fade(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(fade(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? mint.opacity(0.7) : fade(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .entry(let id)?:
            if let entry = catalog.entries.first(where: { $0.id == id }) { entryDetail(entry) }
        case .build?:
            buildDetail
        case nil:
            Text("Select an extension to see what it does and what it can access.")
                .font(.system(size: 13.5)).foregroundStyle(fade(0.55)).multilineTextAlignment(.center)
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryDetail(_ entry: CatalogEntry) -> some View {
        let installed = host.installed.first { $0.id == entry.id }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Tile(tint: entry.tint, icon: ExtensionIcons.symbol(entry.icon) ?? "puzzlepiece.extension", size: 60, radius: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(entry.name)).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("\(L(entry.author)) · v\(installed?.manifest.version ?? entry.version) · \(entry.license)")
                        .font(.system(size: 12.5)).foregroundStyle(fade(0.55))
                }
            }
            Text(L(entry.description)).font(.system(size: 13.5)).lineSpacing(13.5 * 0.55 - 3).foregroundStyle(fade(0.8))
                .fixedSize(horizontal: false, vertical: true)
            does(entry.does)
            access(entry.permissions.lines.map { ($0.symbol, $0.label, $0.detail, $0.mono, nil) }, never: true)
            if let installed {
                installedControls(entry, installed)
            } else {
                MintButton(title: busy == entry.id ? "Installing…" : "Install", height: 44, radius: 13, size: 14) {
                    failure = nil
                    consent = entry
                }
                .disabled(busy != nil)
            }
            if let failure { Text(L(failure)).font(.system(size: 12)).foregroundStyle(SettingsDesign.warn).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(28)
        .id(entry.id)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay {
            if let consent, consent.id == entry.id {
                let granted = installed?.state.granted
                ConsentSheet(name: entry.name, permissions: entry.permissions, new: granted.map(entry.permissions.added(since:)),
                             cancel: { self.consent = nil },
                             allow: { install(entry) })
            }
        }
    }

    private func installedControls(_ entry: CatalogEntry, _ installed: InstalledExtension) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if ExtensionCatalog.hasUpdate(entry, installed: installed) {
                MintButton(title: busy == entry.id ? "Updating…" : String(localized: "Update to v\(entry.version)"), height: 38, radius: 11, size: 13.5) {
                    failure = nil
                    // More permissions than were allowed: ask again, showing the new ones.
                    if entry.permissions.added(since: installed.state.granted).isEmpty { install(entry) } else { consent = entry }
                }
                .disabled(busy != nil)
            }
            HStack {
                Text("Show in the notch").font(.system(size: 13.5))
                Spacer()
                DesignSwitch(isOn: installed.state.enabled, label: "Show in the notch") { host.setEnabled(entry.id, !installed.state.enabled) }
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(fade(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(fade(0.07), lineWidth: 1))
            HStack(spacing: 8) {
                Button { settingsFor = SheetID(id: entry.id) } label: {
                    Text("Extension settings").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(fade(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(installed.manifest.settings.isEmpty)
                Button { host.uninstall(entry.id) } label: {
                    Text("Uninstall").font(.system(size: 13, weight: .semibold)).foregroundStyle(surface(0xFF9A9A, light: 0xC9302C))
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(SettingsDesign.hex(0xFF6B6B, 0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var buildDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Tile(tint: nil, icon: "chevron.left.forwardslash.chevron.right", size: 60, radius: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build your own").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("Orilio · GPL-3.0-or-later").font(.system(size: 12.5)).foregroundStyle(fade(0.55))
                }
            }
            Text("Extensions describe what to show; Orilio draws it with its own components, so every extension looks native. Start from Prayer Times: its README explains the manifest line by line.")
                .font(.system(size: 13.5)).lineSpacing(13.5 * 0.55 - 3).foregroundStyle(fade(0.8))
                .fixedSize(horizontal: false, vertical: true)
            does(["Widgets for the ear and the island", "Actions and reminders", "Permissions you declare up front"])
            access([("shippingbox", "Template", "github.com/enbiyagoral/orilio — extensions", true, ExtensionCatalog.buildYourOwnURL)], never: false)
            if host.developerMode {
                MintButton(title: "Load extension folder…", height: 44, radius: 13, size: 14) { loadFolder() }
            }
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func does(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IN THE NOTCH").font(.system(size: 11.5, weight: .semibold)).tracking(0.92).foregroundStyle(fade(0.5))
            ForEach(lines, id: \.self) { line in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(mint)
                    Text(L(line))
                }
                .font(.system(size: 13)).foregroundStyle(fade(0.8))
            }
        }
    }

    private func access(_ lines: [(String, String, String, Bool, URL?)], never: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAN ACCESS").font(.system(size: 11.5, weight: .semibold)).tracking(0.92).foregroundStyle(fade(0.5))
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let row = HStack(spacing: 10) {
                        Image(systemName: line.0).font(.system(size: 13)).foregroundStyle(fade(0.7)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L(line.1)).font(.system(size: 13))
                            Text(L(line.2)).font(line.3 ? mono : .system(size: 11.5)).foregroundStyle(fade(0.5))
                        }
                        Spacer(minLength: 0)
                        if line.4 != nil { Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(fade(0.5)) }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .overlay(alignment: .bottom) { if index < lines.count - 1 { Rectangle().fill(fade(0.05)).frame(height: 1) } }
                    if let url = line.4 {
                        Button { NSWorkspace.shared.open(url) } label: { row.contentShape(Rectangle()) }.buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            }
            .background(fade(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(fade(0.07), lineWidth: 1))
            if never {
                Text("Never: camera, clipboard, Shelf files, screenshots or other extensions’ data.")
                    .font(.system(size: 11.5)).foregroundStyle(fade(0.45))
            }
        }
    }

    // MARK: Actions

    private func install(_ entry: CatalogEntry) {
        consent = nil
        busy = entry.id
        Task {
            defer { busy = nil }
            do {
                await requestExtensionNotifications(entry.permissions)
                try await catalog.install(entry, host: host)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func loadFolder() {
        LocalExtensionLoader.choose(host: host) { failure = $0 }
    }
}

/// Developer Mode's "Load extension folder…": pick a folder, allow what its manifest asks for, install.
@MainActor
enum LocalExtensionLoader {
    static func choose(host: ExtensionHost, failed: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Load")
        panel.message = L("Choose a folder with orilio-extension.json and main.js.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let manifest = try ExtensionPackage.read(folder)
            let alert = NSAlert()
            alert.messageText = String(localized: "Allow \(manifest.name) to:")
            let lines = manifest.permissions.lines.map { "• " + L($0.label) + " — " + L($0.detail) }
            alert.informativeText = (lines.isEmpty ? L("Nothing beyond showing content in Orilio’s widgets.") : lines.joined(separator: "\n"))
                + "\n\n" + L("It runs in its own sandboxed process and can only show content through Orilio’s widgets. You can change this any time.")
            alert.addButton(withTitle: L("Allow & install"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                await requestExtensionNotifications(manifest.permissions)
                do { try host.install(from: folder, granted: manifest.permissions, local: true) } catch { failed(error.localizedDescription) }
            }
        } catch {
            failed(error.localizedDescription)
        }
    }
}

struct SheetID: Identifiable { let id: String }

/// An extension's tile: its icon on a 14% wash of its tint.
private struct Tile: View {
    let tint: String?
    let icon: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let color = tint.map { ExtensionTint.color($0) }
        Image(systemName: icon)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(color ?? fade(0.8))
            .frame(width: size, height: size)
            .background(color.map { $0.opacity(0.14) } ?? fade(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct MintButton: View {
    let title: String
    let height: CGFloat
    let radius: CGFloat
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(L(title)).font(.system(size: size, weight: .semibold)).foregroundStyle(buttonText)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(buttonFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: SettingsDesign.adaptive(dark: SettingsDesign.ns(0x2BFFB8, 0.35), light: .clear), radius: 11) // the glow is the island’s, on dark
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Allow <name> to:" over the detail panel. On an update, what it newly asks for is marked.
private struct ConsentSheet: View {
    let name: String
    let permissions: ExtensionManifest.Permissions
    /// What an update adds over what was allowed; nil for a first install.
    let new: ExtensionManifest.Permissions?
    let cancel: () -> Void
    let allow: () -> Void

    var body: some View {
        let added = Set((new?.lines ?? []).map(\.label))
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(SettingsDesign.adaptive(dark: SettingsDesign.ns(0x0A0A0E, 0.78), light: .black.withAlphaComponent(0.2)))
            VStack(alignment: .leading, spacing: 14) {
                Text("Allow \(name) to:").font(.system(size: 16, weight: .semibold))
                ForEach(permissions.lines, id: \.label) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: line.symbol).font(.system(size: 12)).foregroundStyle(mint).frame(width: 16)
                        (Text(L(line.label)) + Text(" — " + L(line.detail)).foregroundColor(fade(0.5)))
                            .font(.system(size: 13)).lineSpacing(13 * 0.4 - 2).fixedSize(horizontal: false, vertical: true)
                        if added.contains(line.label) {
                            Text("New").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SettingsDesign.amber)
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(SettingsDesign.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
                Text("It runs in its own sandboxed process and can only show content through Orilio’s widgets. You can change this any time.")
                    .font(.system(size: 12)).lineSpacing(12 * 0.45 - 2).foregroundStyle(fade(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: cancel) {
                        Text("Cancel").font(.system(size: 13.5, weight: .medium))
                            .padding(.horizontal, 16).frame(height: 38)
                            .background(fade(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Button(action: allow) {
                        Text(new == nil ? "Allow & install" : "Allow & update").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(buttonText)
                            .padding(.horizontal, 18).frame(height: 38)
                            .background(buttonFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .background(surface(0x202026, light: 0xFFFFFF), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(fade(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Allow extension access")
        }
    }
}

// MARK: - Extension settings

/// The form an extension's manifest describes (the ExtPrayer design's settings panel).
struct ExtensionSettingsView: View {
    let id: String
    let host: ExtensionHost
    let done: () -> Void

    var body: some View {
        if let ext = host.installed.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(L(ext.manifest.name)).font(.system(size: 14.5, weight: .semibold))
                    Text("Extension settings").font(.system(size: 12)).foregroundStyle(fade(0.45))
                    Spacer()
                    Button("Done", action: done).buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mintText).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20).frame(height: 48)
                .overlay(alignment: .bottom) { Rectangle().fill(fade(0.06)).frame(height: 1) }
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        ForEach(Array(ext.manifest.settings.enumerated()), id: \.offset) { index, setting in
                            HStack {
                                Text(L(setting.label)).font(.system(size: 13.5))
                                Spacer(minLength: 12)
                                control(ext, setting)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 52)
                            .overlay(alignment: .bottom) {
                                if index < ext.manifest.settings.count - 1 { Rectangle().fill(fade(0.05)).frame(height: 1) }
                            }
                        }
                    }
                    .background(fade(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(fade(0.07), lineWidth: 1))
                    if ext.manifest.permissions.notifications {
                        Text("Reminders are scheduled with macOS notifications, so they arrive even when Orilio is closed.")
                            .font(.system(size: 12)).lineSpacing(12 * 0.45 - 2).foregroundStyle(fade(0.5))
                    }
                    HStack(spacing: 8) {
                        ForEach(ext.manifest.permissions.network, id: \.self) { chip($0, mono: true) }
                        if ext.manifest.permissions.notifications { chip("Notifications") }
                        if ext.manifest.permissions.location != nil { chip("City only — no GPS") }
                        if ext.manifest.permissions.network.isEmpty { chip("No internet") }
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
            }
            .frame(width: 640)
            .foregroundStyle(ink)
            .background(SettingsDesign.window)
        }
    }

    private func chip(_ text: String, mono: Bool = false) -> some View {
        Text(L(text)).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12)).foregroundStyle(fade(0.6))
            .padding(.horizontal, 9).frame(height: 24)
            .background(fade(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private func control(_ ext: InstalledExtension, _ setting: ExtensionManifest.Setting) -> some View {
        let value = host.setting(ext, setting)
        let set = { (new: JSONValue) in host.setSetting(ext.id, key: setting.key, value: new) }
        switch setting.type {
        case .city:
            CityPicker(city: value?.object) { set($0) }
        case .select:
            PopUpButton(options: (setting.options ?? []).map { ($0.value, $0.label) }, selection: value ?? .null) { set($0) }
        case .choice:
            HStack(spacing: 0) {
                ForEach(setting.options ?? [], id: \.value) { option in
                    let active = option.value == value
                    Button { set(option.value) } label: {
                        Text(L(option.label)).font(.system(size: 12.5, weight: active ? .medium : .regular))
                            .foregroundStyle(active ? chosenText : fade(0.8))
                            .padding(.horizontal, 11).frame(height: 26)
                            .background(active ? fade(0.9) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(3)
            .background(fade(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .toggle:
            DesignSwitch(isOn: value?.bool ?? false, label: setting.label) { set(.bool(!(value?.bool ?? false))) }
        }
    }
}

/// A city by name, resolved by macOS to coordinates and a time zone. Never the Mac's own location.
private struct CityPicker: View {
    let city: [String: JSONValue]?
    let pick: (JSONValue) -> Void

    @State private var open = false
    @State private var query = ""
    @State private var results: [CLPlacemark] = []
    @State private var searching = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 12))
                Text(city?["name"]?.string ?? L("Choose a city")).font(.system(size: 13))
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(fade(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("City", text: $query, prompt: Text("Search for a city"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
                ForEach(Array(results.enumerated()), id: \.offset) { _, place in
                    Button { choose(place) } label: {
                        Text(Self.name(place)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
                Text(!searching && results.isEmpty && !query.isEmpty ? "Press Return to search." : "macOS looks the name up with Apple Maps; your location is never used.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 280)
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            let places = (try? await CLGeocoder().geocodeAddressString(text)) ?? []
            results = places.filter { $0.location != nil && $0.timeZone != nil }
            searching = false
        }
    }

    private func choose(_ place: CLPlacemark) {
        guard let location = place.location, let zone = place.timeZone else { return }
        var city: [String: JSONValue] = ["name": .string(Self.name(place)), "latitude": .number(location.coordinate.latitude),
                                         "longitude": .number(location.coordinate.longitude), "timeZone": .string(zone.identifier)]
        // The province, district and country, for extensions that look a place up by name.
        if let region = place.administrativeArea { city["region"] = .string(region) }
        if let locality = place.locality ?? place.subAdministrativeArea { city["locality"] = .string(locality) }
        if let code = place.isoCountryCode { city["countryCode"] = .string(code) }
        pick(.object(city))
        open = false
    }

    private static func name(_ place: CLPlacemark) -> String {
        [place.locality ?? place.name ?? place.administrativeArea, place.country].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Settings › Extensions

/// What's installed, each with its switch, settings and diagnostics; Developer Mode; the catalog.
struct ExtensionsPane: View {
    let host: ExtensionHost
    @State private var settingsFor: SheetID?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Installed")
            SettingsCard {
                if host.installed.isEmpty {
                    SettingRow(title: "No extensions yet", note: "Extensions add widgets to the island. They run sandboxed and only show what Orilio draws.") {
                        DesignButton(title: "Browse extensions…") { ExtensionsWindow.show() }
                    }
                }
                ForEach(Array(host.installed.enumerated()), id: \.element.id) { index, ext in
                    if index > 0 { RowLine() }
                    SettingRow(title: ext.manifest.name, note: Self.diagnostics(ext),
                               noteColor: ext.diagnostics.lastError == nil ? SettingsDesign.secondary : SettingsDesign.warn) {
                        HStack(spacing: 8) {
                            if !ext.manifest.settings.isEmpty { DesignButton(title: "Settings…") { settingsFor = SheetID(id: ext.id) } }
                            DesignButton(title: "Uninstall") { host.uninstall(ext.id) }
                            DesignSwitch(isOn: ext.state.enabled, label: String(localized: "Show \(ext.manifest.name) in the notch")) {
                                host.setEnabled(ext.id, !ext.state.enabled)
                            }
                        }
                    }
                }
            }
            if !host.installed.isEmpty {
                DesignButton(title: "Browse extensions…") { ExtensionsWindow.show() }
            }
            SectionLabel("Developer").padding(.top, 12)
            SettingsCard {
                SettingRow(title: "Developer Mode", note: "Load an extension from a folder on this Mac, without the catalog.") {
                    DesignSwitch(isOn: host.developerMode, label: "Developer Mode") { host.developerMode.toggle() }
                }
                if host.developerMode {
                    RowLine()
                    SettingRow(title: "Load extension folder", note: "A folder with orilio-extension.json and main.js. You’ll be asked to allow what it declares.") {
                        DesignButton(title: "Choose…") { LocalExtensionLoader.choose(host: host) { failure = $0 } }
                    }
                }
            }
            if let failure { Text(L(failure)).font(.system(size: 12)).foregroundStyle(SettingsDesign.warn) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $settingsFor) { sheet in ExtensionSettingsView(id: sheet.id, host: host) { settingsFor = nil } }
    }

    /// "v0.3.0 · last run 14:02 · 3.1 MB", or what went wrong.
    static func diagnostics(_ ext: InstalledExtension) -> String {
        var parts = ["v\(ext.manifest.version)"]
        if ext.state.local { parts.append("from a folder") }
        if let error = ext.diagnostics.lastError {
            parts.append(error)
        } else if let run = ext.diagnostics.lastRun {
            parts.append(String(localized: "last run \(run.formatted(date: .omitted, time: .shortened))"))
            if ext.diagnostics.residentBytes > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(ext.diagnostics.residentBytes), countStyle: .memory))
            }
        } else if !ext.state.enabled {
            parts.append("off")
        }
        return parts.joined(separator: " · ")
    }
}
