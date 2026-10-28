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
        switch module.status {
        case .off:
            ModuleMessage(symbol: "list.clipboard", title: "Keep a history of what you copy",
                          detail: "Starts from now. Kept on this Mac only; items marked private and copies from password managers are skipped.",
                          action: ("Turn On Clipboard History", { Task { await module.enable() } }), tint: mint)
        case .blocked:
            ModuleMessage(symbol: "hand.raised", title: "Clipboard access is off",
                          detail: "macOS is set to deny Orilio reading other apps' copies. Allow it in System Settings › Privacy & Security › Paste from Other Apps.",
                          action: ("Open System Settings", { NSWorkspace.shared.open(ClipboardModule.pasteSettingsURL) }), tint: mint)
        case .on, .paused:
            ClipboardHistory(module: module, library: library)
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
                        .accessibilityLabel("Search clipboard history")
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Design.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Typing needs Orilio to be the active app.
                .onChange(of: searching) { if searching { NSApp.activate() } }
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
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, index: index, now: context.date, copied: module.copiedID == item.id,
                                        module: module, library: library)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(items.count <= 5)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var status: some View {
        if module.status == .paused {
            Button { module.resume() } label: {
                Text("Paused · Resume").font(.system(size: 11.5, weight: .medium)).foregroundStyle(mint)
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
    let index: Int
    let now: Date
    let copied: Bool
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
                Text(copied ? "Copied" : ClipboardPolicy.age(of: item.copiedAt, at: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(copied ? mint : .white.opacity(0.5))
                Text(index < 9 ? "⌘\(index + 1)" : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 24, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(copied ? mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        .accessibilityLabel("\(item.kind.rawValue): \(item.preview)")
        .accessibilityHint(copied ? "Copied" : "Copies it to the clipboard")
    }
}

private struct KindTile: View {
    let kind: ClipItem.Kind

    var body: some View {
        let (symbol, ink): (String, Color) = switch kind {
        case .text: ("text.alignleft", .white)
        case .link: ("link", Design.linkInk)
        case .code: ("chevron.left.forwardslash.chevron.right", mint)
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
                case .code: shape.fill(mint.opacity(0.14))
                case .image: shape.fill(Design.imageGradient)
                default: shape.fill(.white.opacity(0.1))
                }
            }
    }
}
