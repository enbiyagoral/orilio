import AppKit
import Quartz
import SwiftUI

/// The AppKit layer under a shelf tile: click to select, double-click to open, right-click for the
/// menu, and dragging out, one item or the whole selection. SwiftUI's drag API carries a single
/// item, so the drag uses `NSDraggingSession` directly.
struct ShelfTileInteraction: NSViewRepresentable {
    let item: ShelfItem
    let shelf: ShelfModel
    /// Called when a drag out finished; `true` if something received the items.
    let dragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfTileInteractionView { ShelfTileInteractionView() }

    func updateNSView(_ view: ShelfTileInteractionView, context: Context) {
        view.item = item
        view.shelf = shelf
        view.dragEnded = dragEnded
    }
}

final class ShelfTileInteractionView: NSView, NSDraggingSource {
    var item: ShelfItem?
    weak var shelf: ShelfModel?
    var dragEnded: ((Bool) -> Void)?
    private var pressed: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        if event.clickCount == 2, let item, let shelf {
            pressed = nil
            shelf.open(shelf.targets(for: item))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressed, let item, let shelf else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return } // a small wobble is still a click
        pressed = nil
        let dragged = shelf.targets(for: item).filter(\.isAvailable)
        guard !dragged.isEmpty else { return }

        let size = NSSize(width: 40, height: 40)
        let origin = convert(start.locationInWindow, from: nil)
        let items = dragged.enumerated().map { index, entry in
            let drag = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
            // A small fan, so several items read as several.
            let offset = CGFloat(index) * 4
            drag.setDraggingFrame(NSRect(x: origin.x - size.width / 2 + offset, y: origin.y - size.height / 2 - offset,
                                         width: size.width, height: size.height),
                                  contents: NSWorkspace.shared.icon(forFile: entry.url.path))
            return drag
        }
        let session = beginDraggingSession(with: items, event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed != nil, let item, let shelf else { return }
        pressed = nil
        shelf.select(item.id, extending: event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift))
        // Choosing a tile is deliberate, so take the keyboard for Space, ⌫ and ⌘C.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKey()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let shelf else { return nil }
        if !shelf.selection.contains(item.id) { shelf.select(item.id, extending: false) }
        let targets = shelf.targets(for: item)
        let available = targets.contains(where: \.isAvailable)
        let menu = NSMenu()
        menu.addItem(MenuAction("Open", enabled: available) { shelf.open(targets) })
        menu.addItem(MenuAction("Quick Look", enabled: available) { QuickLook.show(targets) })
        menu.addItem(MenuAction("Show in Finder", enabled: available) { shelf.reveal(targets) })
        menu.addItem(MenuAction("Copy", enabled: available) { shelf.copy(targets) })
        menu.addItem(.separator())
        menu.addItem(MenuAction(targets.count > 1 ? "Remove \(targets.count) Items from Shelf" : "Remove from Shelf") {
            shelf.remove(targets) // never deletes the user's files
        })
        return menu
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never `.move`: Finder would move the user's original out of its folder.
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded?(operation != [])
    }
}

/// An `NSMenuItem` that runs a closure.
private final class MenuAction: NSMenuItem {
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

/// The system Quick Look panel for shelf items. The island panel hands control to `QuickLook.source`
/// through the responder chain (see `IslandPanel`).
@MainActor
enum QuickLook {
    static let source = QuickLookSource()

    static func show(_ items: [ShelfItem]) {
        let urls = items.filter(\.isAvailable).map(\.url)
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
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

    static func toggle(_ items: [ShelfItem]) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible { panel.orderOut(nil) } else { show(items) }
    }
}

final class QuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
