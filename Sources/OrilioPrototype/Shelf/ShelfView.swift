// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Shown while a drag is over the island (the M5 Moments design: "Release to add 3 files").
struct DropTargetView: View {
    let valid: Bool
    var count = 1
    var destination = "Shelf"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(spacing: 10) {
            if !valid {
                Image(systemName: "nosign")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(Metrics.secondaryText))
            }
            Text(valid ? title : "This can't go on the \(destination)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valid ? .white : .white.opacity(Metrics.secondaryText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(valid ? accent(.action).opacity(0.06) : .clear, in: shape)
        .overlay(shape.strokeBorder(valid ? accent(.action) : .white.opacity(0.2),
                                    style: StrokeStyle(lineWidth: valid ? 2 : 1.5, dash: valid ? [] : [5, 4])))
        .shadow(color: valid ? accent(.action).opacity(0.25) : .clear, radius: 12)
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 14, trailing: 14))
        .animation(.easeInOut(duration: 0.15), value: valid)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let what = count == 1 ? "1 file" : "\(count) files"
        return destination == "Shelf" ? "Release to add \(what)" : "Release to add \(what) to \(destination)"
    }
}

/// The Shelf tab: Files and Screenshots.
struct ShelfView: View {
    let shelf: ShelfModel
    let library: ScreenshotLibrary
    @Binding var section: ShelfSection
    /// Called after items were dragged out and received somewhere: the island can step aside.
    var draggedOut: () -> Void = {}
    @Namespace private var sections
    @State private var confirmClear = false

    var body: some View {
        Group {
            if section == .files, let item = shelf.previewedItem {
                ShelfQuickLook(item: item, shelf: shelf)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    switch section {
                    case .files: FilesStrip(shelf: shelf, screenshotsComeIn: library.addsSystemScreenshots, draggedOut: draggedOut)
                    case .screenshots: ScreenshotsView(library: library)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = shelf.toast, section == .files, shelf.previewing == nil { ShelfToast(toast: toast) { shelf.undoRemove() }.transition(.opacity) }
        }
        .animation(Theme.current.spring(duration: 0.3, bounce: 0.1), value: section)
        .animation(.easeInOut(duration: 0.2), value: shelf.problem)
        .animation(.easeInOut(duration: 0.2), value: library.problem)
        .animation(.easeOut(duration: 0.2), value: shelf.toast)
        .animation(.easeOut(duration: 0.22), value: shelf.previewing)
        // Once each time the shelf is shown: files may have moved or been deleted meanwhile.
        .task { shelf.refreshAvailability() }
        .confirmationDialog("Remove all \(shelf.items.count) items from the Shelf?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) { shelf.clearAll() }
        } message: {
            Text("The files stay where they are.")
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(ShelfSection.allCases) { item in
                Button(title(for: item)) { section = item } // animated below, see IslandModel.relayout
                .buttonStyle(TabButtonStyle(selected: section == item, namespace: sections))
            }
            Spacer(minLength: 8)
            if let problem = section == .files ? shelf.problem : library.problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if section == .files, !shelf.items.isEmpty {
                // The M5 dense design's header: "· 20 items · 1.2 GB", Select, Clear all…
                HStack(spacing: 6) {
                    Text("\(shelf.items.count) \(shelf.items.count == 1 ? "item" : "items") · \(ByteCountFormatter.string(fromByteCount: shelf.totalSize, countStyle: .file))")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .padding(.trailing, 4)
                    HeaderPill(title: shelf.selection.count == shelf.items.count ? "Deselect" : "Select") { shelf.toggleSelectAll() }
                    HeaderPill(title: "Clear all…") { confirmClear = true }
                }
            }
        }
    }

    private func title(for section: ShelfSection) -> String {
        let count = section == .files ? shelf.items.count : library.items.count
        return count > 0 ? "\(section.rawValue) \(count)" : section.rawValue
    }
}

private struct HeaderPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "3 files added" (the M5 Moments design) or "Removed … from Shelf · Undo" (the M5 Shelf design).
private struct ShelfToast: View {
    let toast: ShelfModel.Toast
    let undo: () -> Void

    var body: some View {
        if toast.undoable {
            HStack(spacing: 12) {
                Text(toast.text).lineLimit(1).truncationMode(.middle)
                Button(action: undo) {
                    Text("Undo").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12.5))
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 34)
            .background(Color(red: 40 / 255, green: 40 / 255, blue: 46 / 255, opacity: 0.95), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .padding(.bottom, -6)
        } else {
            Text(toast.text)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.black.opacity(0.6), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, -6)
        }
    }
}

private extension FilesStrip {
    /// Asks where the file is now (the open panel is Orilio's own; no permission is needed).
    func locate(_ item: ShelfItem) {
        let panel = NSOpenPanel()
        panel.message = "Where is \(item.name) now?"
        panel.canChooseDirectories = item.isFolder
        panel.canChooseFiles = !item.isFolder
        panel.directoryURL = item.url.deletingLastPathComponent()
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { shelf.relocate(item, to: url) }
    }
}

private struct FilesStrip: View {
    let shelf: ShelfModel
    let screenshotsComeIn: Bool
    let draggedOut: () -> Void
    /// Dense: the last tile counts what's hidden ("+9"); clicking it shows everything, scrolling.
    @State private var showsAll = false
    static let denseTiles = 12

    /// Past this many, the M5 dense design: six smaller tiles a row, two rows visible, the rest scroll.
    static let denseAfter = 10

    var body: some View {
        let state = ShelfCardState.resolve(shelf.items, pending: shelf.pending.count)
        let count = shelf.items.count + shelf.pending.count
        let dense = count > Self.denseAfter
        if state == .empty {
            // The design says screenshots land on the Shelf; in Orilio they go to Screenshots, and
            // only when that's turned on, so the line says what really happens.
            StatusCard(tone: .empty, symbol: "tray.and.arrow.down", title: "Drop files here",
                       detail: screenshotsComeIn ? "New screenshots from ⇧⌘4 go to Screenshots." : "They stay where they are; the Shelf only keeps a link.")
        } else {
            // The M3 hub design: five tiles a row (radius 16, padding 10, gap 10) over a drop hint.
            VStack(spacing: 12) {
                // The M5 Errors design: a file only in iCloud says so, with one way to get it.
                if let cloud = shelf.items.first(where: { $0.cloud == .cloudOnly }) {
                    HStack {
                        Text("\(cloud.name) is in iCloud only").foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button { shelf.download([cloud]) } label: {
                            Text("Download").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                if case .missing(let id) = state, let item = shelf.items.first(where: { $0.id == id }) {
                    StatusCard(tone: .warn, symbol: "doc.badge.ellipsis", title: "File moved or deleted",
                               detail: "\(item.name) is no longer where it was.",
                               primary: .init("Locate…") { locate(item) }, secondary: .init("Remove") { shelf.remove(item) },
                               layout: .banner)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: dense ? 8 : 10), count: dense ? 6 : 5),
                              spacing: dense ? 8 : 10) {
                        let folded = dense && !showsAll && count > Self.denseTiles
                        let shown = folded ? Self.denseTiles - 1 - min(shelf.pending.count, Self.denseTiles - 1) : shelf.items.count
                        ForEach(shelf.pending.prefix(Self.denseTiles - 1)) { PendingTile(pending: $0, dense: dense) }
                        ForEach(shelf.items.prefix(shown)) { item in
                            ShelfTile(item: item, shelf: shelf, dense: dense, draggedOut: draggedOut)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        if folded {
                            MoreTile(count: count - (Self.denseTiles - 1)) { showsAll = true }
                        }
                    }
                    .animation(.spring(duration: 0.3, bounce: 0), value: shelf.items)
                }
                .scrollIndicators(.never)
                .scrollDisabled(count <= (dense ? Self.denseTiles : 5) || (dense && !showsAll))
                // A soft fade where the list runs on below (once everything is shown, or past five tiles).
                .bottomFade(dense ? showsAll : count > 5)
                if !dense { DropHint() }
            }
        }
    }
}

private struct ThumbnailBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let shelf: ShelfModel
    let dense: Bool
    let draggedOut: () -> Void
    @State private var hovering = false

    var body: some View {
        let selected = shelf.selection.contains(item.id)
        let fresh = shelf.recentlyAdded.contains(item.id)
        let shape = RoundedRectangle(cornerRadius: dense ? 12 : 16, style: .continuous)
        let showsActions = hovering && item.isAvailable && !dense
        VStack(alignment: .leading, spacing: dense ? 5 : 8) {
            TileThumbnail(item: item, dense: dense, dimmed: showsActions)
                .anchorPreference(key: ThumbnailBounds.self, value: .bounds) { $0 }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.isAvailable ? item.name : "Missing: \(item.name)")
                    .font(.system(size: dense ? 10.5 : 12))
                    .foregroundStyle(item.isAvailable ? .white.opacity(dense ? 0.8 : 1) : .orange)
                    .lineLimit(1)
                    .truncationMode(.middle) // the extension stays visible
                if !dense {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
        }
        .padding(dense ? 6 : 10)
        .frame(height: dense ? 92 : 146)
        .background(selected ? accent(.rest).opacity(0.16) : .white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(ring(selected: selected, fresh: fresh), lineWidth: selected ? 1 : 1.5))
        .shadow(color: fresh ? accent(.action).opacity(0.25) : .clear, radius: 7)
        .opacity(item.cloud == .cloudOnly ? 0.7 : 1)
        // Clicks, double-clicks, the context menu and dragging out are handled in AppKit underneath.
        .overlay { TileInteraction(actions: .shelf(item, in: shelf, draggedOut: draggedOut)) }
        // The M5 Shelf design's hover actions, over the thumbnail and above the AppKit layer.
        .overlayPreferenceValue(ThumbnailBounds.self) { anchor in
            GeometryReader { proxy in
                if showsActions, let anchor {
                    let rect = proxy[anchor]
                    TileActions(item: item, shelf: shelf)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .transition(.opacity)
                }
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { shelf.hovered = item.id } else if shelf.hovered == item.id { shelf.hovered = nil }
        }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.6), value: fresh)
        .help(item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { shelf.select(item.id, extending: false) }
        .accessibilityAction(named: "Open") { shelf.open([item]) }
        .accessibilityAction(named: "Quick Look") { shelf.preview(item) }
        .accessibilityAction(named: "Show in Finder") { shelf.reveal([item]) }
        .accessibilityAction(named: "Remove from Shelf") { shelf.remove(item) }
    }

    private func ring(selected: Bool, fresh: Bool) -> Color {
        if selected { return accent(.rest).opacity(0.7) }
        if fresh { return accent(.action).opacity(0.7) }
        if hovering { return .white.opacity(0.5) }
        return .clear
    }

    private var detail: String {
        if !item.isAvailable { return "Missing" }
        switch item.cloud {
        case .cloudOnly: return "In iCloud"
        case .downloading: return "Downloading…"
        case .local: break
        }
        if item.isFolder { return "Folder" }
        return item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? item.contentType?.localizedDescription ?? ""
    }
}

/// Open · Quick Look · Remove (34 pt, radius 10; Quick Look white).
private struct TileActions: View {
    let item: ShelfItem
    let shelf: ShelfModel

    var body: some View {
        HStack(spacing: 6) {
            action("arrow.up.right.square", "Open \(item.name)", primary: false) { shelf.open([item]) }
            action("eye", "Quick Look \(item.name)", primary: true) { shelf.preview(item) }
            action("xmark", "Remove \(item.name) from Shelf", primary: false) { shelf.remove(item) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func action(_ symbol: String, _ label: String, primary: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primary ? .black : .white)
                .frame(width: 34, height: 34)
                .background(primary ? Color.white : .white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The M5 dense design's last tile: how many more there are.
private struct MoreTile: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text("+\(count)").font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("\(count) more").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            .padding(6)
            .frame(height: 92)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Show all files")
        .accessibilityLabel("\(count) more files. Show all")
    }
}

private struct PendingTile: View {
    let pending: ShelfModel.Pending
    var dense = false

    var body: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(pending.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .frame(height: dense ? 92 : 146)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: dense ? 12 : 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Receiving \(pending.name)")
    }
}

/// The tile's picture: a real thumbnail for images, the file's icon for everything else, with
/// its kind (PNG, PDF, ZIP…) in the corner. An iCloud-only file is a striped placeholder with a
/// cloud; one coming down shows a ring.
private struct TileThumbnail: View {
    let item: ShelfItem
    var dense = false
    /// Under the hover actions: dark and blurred.
    var dimmed = false
    @State private var thumbnail: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: dense ? 8 : 10, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            // In an overlay, so a filling thumbnail can't widen the tile.
            shape.fill(.white.opacity(0.06)).overlay { picture }
                .blur(radius: dimmed ? 6 : 0)
                .overlay { if dimmed { Color.black.opacity(0.55) } }
            if let kind, !dense, item.cloud == .local {
                Text(kind)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .task(id: item.url) { await loadThumbnail() }
    }

    @ViewBuilder private var picture: some View {
        switch item.cloud {
        case .cloudOnly:
            ZStack {
                Stripes()
                RoundedRectangle(cornerRadius: dense ? 8 : 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                Image(systemName: "icloud").font(.system(size: dense ? 16 : 22, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
        case .downloading:
            DownloadRing().frame(width: dense ? 30 : 44, height: dense ? 30 : 44)
        case .local:
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: dense ? 32 : 44, height: dense ? 32 : 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var kind: String? {
        if item.isFolder { return "FOLDER" }
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty || ext.count > 5 ? nil : ext
    }

    /// Images only: everything else reads fine as its icon, and thumbnails cost a render each.
    private func loadThumbnail() async {
        guard item.isAvailable, item.cloud == .local, item.contentType?.conforms(to: .image) == true else { return }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 120, height: 100),
                                                   scale: 2, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// The M5 Errors design's "In iCloud" placeholder: 45° stripes of 4% white, 6 pt apart.
private struct Stripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 12
            }
            context.stroke(path, with: .color(.white.opacity(0.04)), lineWidth: 6)
        }
    }
}

/// Downloading from iCloud: the design's ring (3.5 pt on 18% white). iCloud reports no progress
/// to Orilio, so the arc turns instead of filling.
private struct DownloadRing: View {
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 3.5)
            Circle().trim(from: 0, to: 0.3).stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 270 : -90))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityLabel("Downloading from iCloud")
    }
}

/// The design's hint under the tiles.
private struct DropHint: View {
    var body: some View {
        Label("Drop files here · they stay where they are; the Shelf keeps a link", systemImage: "square.and.arrow.down")
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1.5))
            .accessibilityElement(children: .combine)
    }
}
