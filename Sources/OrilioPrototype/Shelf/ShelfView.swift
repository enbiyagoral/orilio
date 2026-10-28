import AppKit
import SwiftUI

/// Shown while a drag is over the island.
struct DropTargetView: View {
    let valid: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.previewInnerRadius, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: valid ? "tray.and.arrow.down.fill" : "nosign")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(valid ? mint : .white.opacity(Metrics.secondaryText))
            Text(valid ? "Drop to add to Shelf" : "This can't go on the Shelf")
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
    enum Section: String, CaseIterable, Identifiable {
        case files = "Files"
        case screenshots = "Screenshots"
        var id: Self { self }
    }

    let shelf: ShelfModel
    @State private var section = Section.files
    @Namespace private var sections
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Section.allCases) { item in
                    Button(item == .files && !shelf.items.isEmpty ? "\(item.rawValue) \(shelf.items.count)" : item.rawValue) {
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1)) { section = item }
                    }
                    .buttonStyle(TabButtonStyle(selected: section == item, namespace: sections))
                }
                Spacer(minLength: 8)
                if let problem = shelf.problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            switch section {
            case .files: FilesStrip(shelf: shelf)
            case .screenshots: ScreenshotsPlaceholder()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shelf.problem)
    }
}

private struct FilesStrip: View {
    let shelf: ShelfModel

    var body: some View {
        if shelf.items.isEmpty && shelf.pending.isEmpty {
            EmptyShelf()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(shelf.pending) { PendingTile(pending: $0) }
                    ForEach(shelf.items) { item in
                        ShelfTile(item: item) { shelf.remove(item) }
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3, bounce: 0), value: shelf.items)
            }
            .frame(height: 84)
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
                .lineLimit(1)
        }
        .frame(width: 78, height: 80)
        .background(.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from Shelf", action: remove) // never deletes the file
        }
        .help(item.url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(detail)")
        .accessibilityAction(named: "Open") { NSWorkspace.shared.open(item.url) }
        .accessibilityAction(named: "Remove from Shelf", remove)
    }

    private var detail: String {
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
        .frame(width: 78, height: 80)
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

private struct ScreenshotsPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
            Text("The screenshot library is on its way.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .accessibilityElement(children: .combine)
    }
}
