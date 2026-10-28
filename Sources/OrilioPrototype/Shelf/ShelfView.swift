import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Shown while a drag is over the island.
struct DropTargetView: View {
    let valid: Bool
    var destination = "Shelf"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.previewInnerRadius, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: valid ? "tray.and.arrow.down.fill" : "nosign")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(valid ? mint : .white.opacity(Metrics.secondaryText))
            Text(valid ? "Drop to add to \(destination)" : "This can't go on the \(destination)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valid ? .white : .white.opacity(Metrics.secondaryText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(valid ? mint.opacity(0.08) : .clear, in: shape)
        .overlay(shape.strokeBorder(valid ? mint.opacity(0.9) : .white.opacity(0.2),
                                    style: StrokeStyle(lineWidth: 1.5, dash: valid ? [] : [5, 4])))
        .padding(Metrics.previewPadding)
        .animation(.easeInOut(duration: 0.15), value: valid)
        .accessibilityElement(children: .combine)
    }
}

/// The Shelf tab: Files now, Screenshots in M2.3.
struct ShelfView: View {
    let shelf: ShelfModel
    let library: ScreenshotLibrary
    @Binding var section: ShelfSection
    /// Called after items were dragged out and received somewhere: the island can step aside.
    var draggedOut: () -> Void = {}
    @Namespace private var sections
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                }
            }
            switch section {
            case .files: FilesStrip(shelf: shelf, draggedOut: draggedOut)
            case .screenshots: ScreenshotsView(library: library)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: section)
        .animation(.easeInOut(duration: 0.2), value: shelf.problem)
        .animation(.easeInOut(duration: 0.2), value: library.problem)
        // Once each time the shelf is shown: files may have moved or been deleted meanwhile.
        .task { shelf.refreshAvailability() }
    }

    private func title(for section: ShelfSection) -> String {
        let count = section == .files ? shelf.items.count : library.items.count
        return count > 0 ? "\(section.rawValue) \(count)" : section.rawValue
    }
}

private struct FilesStrip: View {
    let shelf: ShelfModel
    let draggedOut: () -> Void

    var body: some View {
        if shelf.items.isEmpty && shelf.pending.isEmpty {
            EmptyShelf()
        } else {
            // The M3 hub design: five tiles a row (radius 16, padding 10, gap 10) over a drop hint.
            VStack(spacing: 12) {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(shelf.pending) { PendingTile(pending: $0) }
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, shelf: shelf, draggedOut: draggedOut)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3, bounce: 0), value: shelf.items)
                }
                .scrollIndicators(.never)
                .scrollDisabled(shelf.items.count + shelf.pending.count <= 5)
                DropHint()
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let shelf: ShelfModel
    let draggedOut: () -> Void
    @State private var hovering = false

    var body: some View {
        let selected = shelf.selection.contains(item.id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                TileThumbnail(item: item)
                    .saturation(item.isAvailable ? 1 : 0)
                    .opacity(item.isAvailable ? 1 : 0.4)
                Text(item.isAvailable ? item.name : "Missing: \(item.name)")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isAvailable ? .white : .orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(height: 146)
            .background(selected ? mint.opacity(0.16) : .white.opacity(hovering ? 0.08 : 0.05), in: shape)
            .overlay(shape.strokeBorder(selected ? mint.opacity(0.7) : .white.opacity(0.08), lineWidth: 1))
            // Clicks, double-clicks, the context menu and dragging out are handled in AppKit underneath.
            .overlay { TileInteraction(actions: .shelf(item, in: shelf, draggedOut: draggedOut)) }

            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Remove from Shelf")
                .accessibilityLabel("Remove \(item.name) from Shelf")
                .padding(2)
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .help(item.isAvailable ? item.url.path : "Missing: \(item.url.path)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { shelf.select(item.id, extending: false) }
        .accessibilityAction(named: "Open") { shelf.open([item]) }
        .accessibilityAction(named: "Quick Look") { QuickLook.show([item]) }
        .accessibilityAction(named: "Show in Finder") { shelf.reveal([item]) }
        .accessibilityAction(named: "Remove from Shelf") { shelf.remove(item) }
    }

    private var detail: String {
        if !item.isAvailable { return "Missing" }
        if item.isFolder { return "Folder" }
        return item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? item.contentType?.localizedDescription ?? ""
    }
}

private struct PendingTile: View {
    let pending: ShelfModel.Pending

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
        .frame(height: 146)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Receiving \(pending.name)")
    }
}

private struct EmptyShelf: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop files on the notch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("They stay where they are; the Shelf only keeps a link.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(Metrics.secondaryText))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .overlay(shape.strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}

/// The tile's picture: a real thumbnail for images, the file's icon for everything else, with
/// its kind (PNG, PDF, ZIP…) in the corner.
private struct TileThumbnail: View {
    let item: ShelfItem
    @State private var thumbnail: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            // In an overlay, so a filling thumbnail can't widen the tile.
            shape.fill(.white.opacity(0.06)).overlay { picture }
            if let kind {
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
        if let thumbnail {
            Image(decorative: thumbnail, scale: 2).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 44, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var kind: String? {
        if item.isFolder { return "FOLDER" }
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty || ext.count > 5 ? nil : ext
    }

    /// Images only: everything else reads fine as its icon, and thumbnails cost a render each.
    private func loadThumbnail() async {
        guard item.isAvailable, item.contentType?.conforms(to: .image) == true else { return }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 120, height: 100),
                                                   scale: 2, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
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
