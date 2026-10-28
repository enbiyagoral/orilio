// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI

/// The screenshot grid, in AppKit. `NSCollectionView` recycles its cells, so a library of
/// thousands keeps only the visible cells (plus a small prefetch window) alive, each drawing one
/// small cached thumbnail into its layer. SwiftUI's lazy grid never releases cells it has created,
/// which made memory grow with every row scrolled.
struct ScreenshotGrid: NSViewRepresentable {
    let library: ScreenshotLibrary

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 114, height: 66)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8

        let grid = GridView()
        grid.collectionViewLayout = layout
        grid.backgroundColors = [.clear]
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.register(ScreenshotCell.self, forItemWithIdentifier: ScreenshotCell.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        // Never `.move`: dragging a screenshot out leaves the library's copy in place.
        grid.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        grid.setDraggingSourceOperationMask([], forLocal: true)
        grid.onOpen = { [weak coordinator = context.coordinator] in coordinator?.open($0) }
        grid.menuProvider = { [weak coordinator = context.coordinator] in coordinator?.menu(for: $0) }
        grid.setAccessibilityLabel("Screenshots")

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.appearance = NSAppearance(named: .darkAqua)
        context.coordinator.grid = grid
        context.coordinator.reload(library.items)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.library = library
        context.coordinator.reload(library.items)
        context.coordinator.syncSelection(library.selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var library: ScreenshotLibrary
        weak var grid: NSCollectionView?
        private var items: [ScreenshotItem] = []

        init(library: ScreenshotLibrary) { self.library = library }

        /// Reloads only when the list itself changed (an import, a removal, the sort order).
        func reload(_ next: [ScreenshotItem]) {
            guard next.map(\.id) != items.map(\.id) else { return }
            items = next
            grid?.reloadData()
            syncSelection(library.selection)
        }

        func syncSelection(_ ids: Set<UUID>) {
            guard let grid else { return }
            let paths = Set(items.indices.filter { ids.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
            if grid.selectionIndexPaths != paths { grid.selectionIndexPaths = paths }
        }

        private func selectionFromGrid() {
            guard let grid else { return }
            library.setSelection(Set(grid.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil }))
        }

        func open(_ path: IndexPath) {
            guard items.indices.contains(path.item) else { return }
            QuickLook.show(urls: library.targets(for: items[path.item]).map(library.imageURL))
        }

        func menu(for path: IndexPath) -> NSMenu? {
            guard items.indices.contains(path.item) else { return nil }
            let item = items[path.item]
            if !library.selection.contains(item.id) { library.select(item.id, extending: false) }
            return ScreenshotMenu.make(for: library.targets(for: item), in: library)
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: ScreenshotCell.identifier, for: indexPath)
            (cell as? ScreenshotCell)?.show(items[indexPath.item], store: library.store)
            return cell
        }

        // MARK: Selection and dragging out

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionFromGrid() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionFromGrid() }

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            library.imageURL(for: items[indexPath.item]) as NSURL
        }
    }
}

/// Double-click and right-click on the grid; everything else is NSCollectionView's own behavior.
final class GridView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    var menuProvider: ((IndexPath) -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onOpen?(path)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(path)
    }
}

/// One recycled cell: a layer showing a cached thumbnail. Reuse cancels any load still in flight.
final class ScreenshotCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ScreenshotCell")
    private var load: Task<Void, Never>?
    private var showing: UUID?

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        self.view = view
        updateBorder()
    }

    func show(_ item: ScreenshotItem, store: ScreenshotStore) {
        guard showing != item.id else { return }
        showing = item.id
        load?.cancel()
        view.layer?.contents = nil
        let date = item.capturedAt.formatted(date: .abbreviated, time: .shortened)
        view.toolTip = "\(date) · \(item.pixelWidth)×\(item.pixelHeight)"
        view.setAccessibilityLabel("Screenshot, \(date)")
        load = Task { [weak self] in
            let box = await ThumbnailCache.shared.image(for: item, in: store)
            guard !Task.isCancelled, let self, self.showing == item.id else { return }
            let fade = CATransition()
            fade.duration = 0.15
            self.view.layer?.add(fade, forKey: "contents")
            self.view.layer?.contents = box?.image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        load?.cancel()
        showing = nil
        view.layer?.contents = nil
    }

    override var isSelected: Bool {
        didSet { updateBorder() }
    }

    private func updateBorder() {
        view.layer?.borderWidth = isSelected ? 2 : 1
        view.layer?.borderColor = isSelected ? NSColor(accent(.rest)).cgColor : NSColor.white.withAlphaComponent(0.08).cgColor
        view.setAccessibilitySelected(isSelected)
    }
}

/// The context menu for screenshots, worded for what will really happen to the files.
@MainActor
enum ScreenshotMenu {
    static func make(for targets: [ScreenshotItem], in library: ScreenshotLibrary) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction("Preview") { QuickLook.show(urls: targets.map(library.imageURL)) })
        menu.addItem(MenuAction("Copy Image") { library.copy(targets) })
        menu.addItem(MenuAction("Show in Finder") { library.reveal(targets) })
        menu.addItem(.separator())
        let withOriginal = targets.allSatisfy(library.hasExternalOriginal)
        let title = withOriginal
            ? (targets.count > 1 ? "Remove \(targets.count) from Library" : "Remove from Library")
            : (targets.count > 1 ? "Delete \(targets.count) Screenshots" : "Delete Screenshot")
        let remove = MenuAction(title) { library.remove(targets) }
        remove.toolTip = withOriginal
            ? "Orilio's copy moves to the Trash. The original file stays where it is."
            : "Orilio's copy moves to the Trash. It's the only copy."
        menu.addItem(remove)
        return menu
    }
}
