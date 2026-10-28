import AppKit
import Observation

enum IslandState: Equatable {
    case collapsed
    case expanded // hover: a one-row preview; closes when the pointer leaves
    case pinned   // click: the full controller; stays until Esc, close or unpin
    case dropTarget // a drag is over the island: open just enough to take the drop

    var isOpen: Bool { self != .collapsed }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case music = "Music"
    case shelf = "Shelf"
    var id: Self { self }
}

enum SettingsKeys {
    static let openOnHover = "openOnHover"
    static let preferNotchedDisplay = "preferNotchedDisplay"
    static let showDemoSource = "showDemoSource"
}

/// Single source of truth for the island. The window controller only reacts to `onWillChangeState`.
@MainActor @Observable
final class IslandModel {
    // Debounce: a pointer passing over the island shouldn't open it; a brief slip outside shouldn't close it.
    static let openDelay: Duration = .milliseconds(120)
    static let closeDelay: Duration = .milliseconds(350)
    // Open is soft with a touch of overshoot; close is quicker and settles without bounce.
    static let openDuration = 0.5
    static let closeDuration = 0.3

    private(set) var state: IslandState = .collapsed
    var tab: IslandTab = .music
    var geometry = IslandGeometry.fallback
    var hoverOpens = true
    let demo: DemoMediaProvider
    let media: MediaCoordinator
    let shelf: ShelfModel
    /// Whether the drag over the island carries something the shelf can take.
    private(set) var dropIsValid = true

    init(providers: [any MediaProvider] = [], shelf: ShelfModel = ShelfModel()) {
        let showDemo = UserDefaults.standard.bool(forKey: SettingsKeys.showDemoSource)
        demo = DemoMediaProvider(enabled: showDemo)
        media = MediaCoordinator(providers: providers + [demo])
        self.shelf = shelf
    }

    @ObservationIgnored var onWillChangeState: ((IslandState) -> Void)?
    /// A held mouse button (dragging the progress bar past the edge) must not close the island.
    @ObservationIgnored var isPointerBusy: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// False while the shelf opens after a drop: the user is still in their own app, so the
    /// panel shows without taking keyboard focus.
    @ObservationIgnored private(set) var pinTakesFocus = true
    @ObservationIgnored private var stateBeforeDrag: IslandState?

    func hover(_ inside: Bool) {
        pending?.cancel()
        pending = nil
        if inside, state == .collapsed, hoverOpens {
            schedule(.expanded, after: Self.openDelay)
        } else if !inside, state == .expanded {
            schedule(.collapsed, after: Self.closeDelay)
        }
    }

    /// A click anywhere on the island (outside its buttons) opens the full controller.
    func tap() { set(.pinned) }
    func togglePin() { set(state == .pinned ? .expanded : .pinned) }
    func dismiss() { set(.collapsed) }

    // MARK: Dragging onto the island

    func dragEntered(valid: Bool) {
        dropIsValid = valid
        guard state != .dropTarget else { return }
        stateBeforeDrag = state
        set(.dropTarget)
    }

    /// The drag left without dropping: go back to how the island was (a hover preview closes).
    func dragExited() {
        guard state == .dropTarget else { return }
        set(stateBeforeDrag == .pinned ? .pinned : .collapsed)
        stateBeforeDrag = nil
    }

    /// Hands the drop to the shelf and shows it there. Returns whether anything was accepted.
    @discardableResult
    func dropped(_ content: DropContent, sequence: Int) -> Bool {
        let accepted = shelf.accept(content, sequence: sequence)
        stateBeforeDrag = nil
        tab = .shelf
        pinTakesFocus = false
        set(.pinned)
        pinTakesFocus = true
        return accepted
    }

    func set(_ new: IslandState) {
        pending?.cancel()
        pending = nil
        guard new != state else { return }
        // Window first, state second: the panel must already be its new size when SwiftUI
        // starts animating, or one frame renders the island offset from the top edge.
        onWillChangeState?(new)
        if !state.isOpen, new.isOpen { media.refreshAll() }
        state = new
    }

    private func schedule(_ target: IslandState, after delay: Duration) {
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if target == .collapsed, self.isPointerBusy() {
                self.schedule(target, after: delay) // check again once the user lets go
            } else {
                self.set(target)
            }
        }
    }
}
