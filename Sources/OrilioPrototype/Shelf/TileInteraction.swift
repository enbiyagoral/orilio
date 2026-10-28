// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Quartz
import SwiftUI

/// The AppKit layer under a tile (File Shelf and Screenshots): click to select, double-click to
/// open, right-click for the menu, and dragging out, one item or the whole selection. SwiftUI's drag
/// API carries a single item, so the drag uses `NSDraggingSession` directly.
struct TileInteraction: NSViewRepresentable {
    struct Actions {
        /// `extending` when ⌘ or ⇧ is held.
        var select: (_ extending: Bool) -> Void
        var open: () -> Void
        /// Called before the menu shows, so it can act on the right selection.
        var menu: () -> NSMenu?
        /// The files a drag carries (the selection, if this tile is part of it). Empty: no drag.
        var dragURLs: () -> [URL]
        /// `true` if the drag was received somewhere.
        var dragEnded: (Bool) -> Void
    }

    let actions: Actions

    func makeNSView(context: Context) -> TileInteractionView { TileInteractionView() }

    func updateNSView(_ view: TileInteractionView, context: Context) {
        view.actions = actions
    }
}

final class TileInteractionView: NSView, NSDraggingSource {
    var actions: TileInteraction.Actions?
    private var pressed: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        if event.clickCount == 2 {
            pressed = nil
            actions?.open()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed, let actions else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return } // a small wobble is still a click
        pressed = nil
        let urls = actions.dragURLs()
        guard !urls.isEmpty else { return }

        let size = NSSize(width: 40, height: 40)
        let origin = convert(start.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url in
            let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
            // A small fan, so several items read as several.
            let offset = CGFloat(index) * 4
            drag.setDraggingFrame(NSRect(x: origin.x - size.width / 2 + offset, y: origin.y - size.height / 2 - offset,
                                         width: size.width, height: size.height),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return drag
        }
        let session = beginDraggingSession(with: items, event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed != nil, let actions else { return }
        pressed = nil
        actions.select(event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift))
        // Choosing a tile is deliberate, so ask for the keyboard (Space, Delete, ⌘C). Asked every
        // time: AppKit can report Orilio as active while the system still routes keys to the
        // previous app (seen after the non-activating panel became key), so neither `isActive` nor
        // `frontmostApplication` is a reliable reason to skip it. Never done on hover or drag.
        NSApp.activate()
        window?.makeKey()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        actions?.menu()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never `.move`: Finder would move the user's original out of its folder.
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        actions?.dragEnded(operation != [])
    }
}

extension TileInteraction.Actions {
    /// The File Shelf's tile behavior.
    @MainActor
    static func shelf(_ item: ShelfItem, in shelf: ShelfModel, draggedOut: @escaping () -> Void) -> Self {
        var dragged: [UUID] = []
        return Self(
            select: { shelf.select(item.id, extending: $0) },
            open: { shelf.open(shelf.targets(for: item)) },
            menu: {
                if !shelf.selection.contains(item.id) { shelf.select(item.id, extending: false) }
                let targets = shelf.targets(for: item)
                let available = targets.contains(where: \.isAvailable)
                let menu = NSMenu()
                menu.addItem(MenuAction("Open", enabled: available) { shelf.open(targets) })
                menu.addItem(MenuAction("Quick Look", enabled: available) { if let first = targets.first(where: \.isAvailable) { shelf.preview(first) } })
                menu.addItem(MenuAction("Show in Finder", enabled: available) { shelf.reveal(targets) })
                menu.addItem(MenuAction("Copy", enabled: available) { shelf.copy(targets) })
                menu.addItem(.separator())
                menu.addItem(MenuAction(targets.count > 1 ? "Remove \(targets.count) Items from Shelf" : "Remove from Shelf") {
                    shelf.remove(targets) // never deletes the user's files
                })
                return menu
            },
            dragURLs: {
                let targets = shelf.targets(for: item).filter(\.isAvailable)
                dragged = targets.map(\.id)
                shelf.download(targets) // an iCloud-only file comes down while it travels
                return targets.map(\.url)
            },
            dragEnded: { delivered in
                // Dropped into another app: off the Shelf, unless ⌥ is held (the M5 Moments design).
                shelf.finishDragOut(dragged, delivered: delivered, keep: NSEvent.modifierFlags.contains(.option))
                if delivered { draggedOut() }
            })
    }
}

/// An `NSMenuItem` that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool = true, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: enabled ? #selector(runAction) : nil, keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runAction() { run() }
}

/// The system Quick Look panel for screenshots (Shelf files preview inside the island). The island panel hands control to `QuickLook.source`
/// through the responder chain (see `IslandPanel`).
@MainActor
enum QuickLook {
    static let source = QuickLookSource()

    /// Previews files; with `toggle`, closes the panel instead if it is already showing.
    static func show(urls: [URL], toggle: Bool = false) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if toggle, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        source.urls = urls
        // Previewing is deliberate: Quick Look needs Orilio active to receive Space, arrows and Esc.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0 is IslandPanel }?.makeKey()
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
