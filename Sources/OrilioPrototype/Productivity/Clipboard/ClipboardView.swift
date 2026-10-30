// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI

// Values follow the M3 hub design: a 36 pt search field (radius 12) and 38 pt rows (radius 11)
// with a 26 pt kind tile (radius 7) and a ⌘n shortcut.
private enum Design {
    static let field = Color.white.opacity(0.08)
    static let linkInk = Color(red: 0.553, green: 0.733, blue: 1)       // #8DBBFF
    static let linkTile = Color(red: 0.43, green: 0.66, blue: 1).opacity(0.18) // #6EA8FF
    static let imageGradient = LinearGradient(colors: [Color(red: 0.435, green: 0.318, blue: 0.502),  // #6F5180
                                                       Color(red: 0.184, green: 0.431, blue: 0.424)], // #2F6E6C
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The Clipboard module in the island.
struct ClipboardPanel: View {
    @Bindable var module: ClipboardModule
    let library: ScreenshotLibrary

    var body: some View {
        switch ClipboardCardState.resolve(status: module.status, declined: module.declined, isEmpty: module.items.isEmpty,
                                          privacyPaused: module.privacyPaused) {
        case .ask:
            // Opt-in only: no system prompt here.
            StatusCard(tone: .ask(tile: SettingsDesign.mint.opacity(0.12), ink: SettingsDesign.mint), symbol: "list.clipboard",
                       title: "Keep a clipboard history?",
                       detail: String(localized: "Copied text, links and images stay on this Mac for \(keptFor). Password managers and hidden items are always skipped."),
                       primary: .init("Turn on") { Task { await module.enable() } },
                       secondary: .init("Not now") { module.decline() }, layout: .ask)
        case .off:
            StatusCard(tone: .empty, symbol: "list.clipboard", title: "Clipboard history is off",
                       detail: module.retentionDays == 0 ? "Keep your copies, only on this Mac." : String(localized: "Keep the last \(keptFor) of copies, only on this Mac."),
                       primary: .init("Turn on") { Task { await module.enable() } })
        case .blocked:
            StatusCard(tone: .warn, symbol: "hand.raised", title: "Clipboard access is off",
                       detail: "macOS denies Orilio reading other apps’ copies. Allow it in Privacy & Security › Paste from Other Apps.",
                       primary: .init("Open System Settings") { NSWorkspace.shared.open(ClipboardModule.pasteSettingsURL) }, layout: .banner)
        case .privacyPaused:
            StatusCard(tone: .empty, symbol: "pause", title: "Paused for privacy",
                       detail: "A password manager is in front. History resumes when you switch away.")
        case .empty:
            StatusCard(tone: .empty, symbol: "list.clipboard", title: "Copy something",
                       detail: "Text, links and images you copy with ⌘C appear here.")
        case .history:
            ClipboardHistory(module: module, library: library)
        }
    }

    /// The real retention ("7 days"), not a fixed number.
    private var keptFor: String {
        switch module.retentionDays {
        case 0: L("as long as you keep them")
        case 1: L("1 day")
        case let days: String(localized: "\(days) days")
        }
    }
}

private struct ClipboardHistory: View {
    @Bindable var module: ClipboardModule
    let library: ScreenshotLibrary
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    TextField("Search clipboard", text: $module.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searching)
                        .tint(.white) // a white caret, not the system's blue
                        .accessibilityLabel("Search clipboard history")
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Design.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Typing needs Orilio to be the active app.
                .onChange(of: searching) { if searching { NSApp.activate() } }
                // ⌘F, or a letter typed in the list (the M5 Keyboard design).
                .onChange(of: module.searchRequest) { searching = true }
                status
            }
            let items = module.visibleItems
            if items.isEmpty {
                Text(module.query.isEmpty ? "Copy something and it shows up here." : "Nothing matches that search.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // Ages refresh once a minute while the panel is on screen.
                TimelineView(.everyMinute) { context in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                ClipRow(item: item, now: context.date, copied: module.copiedID == item.id,
                                        selected: module.selectedID == item.id, module: module, library: library)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(items.count <= 5)
                    .bottomFade(items.count > 5)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var status: some View {
        if module.status == .paused {
            Button { module.resume() } label: {
                Text("Paused · Resume").font(.system(size: 11.5, weight: .medium)).foregroundStyle(accent(.action))
            }
            .buttonStyle(.plain)
            .help("Copies made while paused are not recorded")
        } else {
            Text(module.readPermission == .ask ? "Local only · macOS asks on each copy" : "Local only · skips password managers")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let now: Date
    let copied: Bool
    var selected = false
    let module: ClipboardModule
    let library: ScreenshotLibrary

    var body: some View {
        Button { Task { await module.copy(item) } } label: {
            HStack(spacing: 10) {
                KindTile(kind: item.kind)
                Text(item.preview)
                    .font(.system(size: 13, design: item.kind == .code ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                Text(copied ? L("Copied") : ClipboardPolicy.age(of: item.copiedAt, at: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(copied ? accent(.rest) : .white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(copied ? accent(.rest).opacity(0.12) : selected ? .white.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            // The keyboard's row: 1.5 pt of 85% white (the M5 Keyboard design).
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(selected ? 0.85 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(item.pinned ? "Unpin" : "Pin") { module.togglePin(item) }
            if item.kind == .image {
                Button("Add to Screenshots") { Task { await module.sendToLibrary(item, library: library) } }
            }
            Divider()
            Button("Remove") { module.remove(item) }
            Button("Clear Unpinned History") { module.clear() }
            Button(module.status == .paused ? "Resume History" : "Pause History") {
                module.status == .paused ? module.resume() : module.pause()
            }
        }
        // The full text, however long (capped: a 10,000-character tooltip helps no one).
        .help(Self.full(item))
        .accessibilityLabel(String(localized: "\(L(item.kind.rawValue)): \(Self.full(item))"))
        .accessibilityHint(copied ? "Copied" : "Copies it to the clipboard")
    }
}

extension ClipRow {
    static let fullTextLimit = 2_000
    static func full(_ item: ClipItem) -> String {
        guard let text = item.text else { return item.preview }
        return text.count > fullTextLimit ? String(text.prefix(fullTextLimit)) + "…" : text
    }
}

private struct KindTile: View {
    let kind: ClipItem.Kind

    var body: some View {
        let (symbol, ink): (String, Color) = switch kind {
        case .text: ("text.alignleft", .white)
        case .link: ("link", Design.linkInk)
        case .code: ("chevron.left.forwardslash.chevron.right", accent(.rest))
        case .image: ("photo", .white)
        case .files: ("doc", .white)
        }
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: 26, height: 26)
            .background {
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                switch kind {
                case .link: shape.fill(Design.linkTile)
                case .code: shape.fill(accent(.rest).opacity(0.14))
                case .image: shape.fill(Design.imageGradient)
                default: shape.fill(.white.opacity(0.1))
                }
            }
    }
}
