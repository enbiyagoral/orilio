import AppKit
import Observation

enum IslandState: Equatable {
    case collapsed
    case expanded // hover: a one-row preview; closes when the pointer leaves
    case pinned   // click: the full controller; stays until Esc, close or unpin
    case dropTarget // a drag is over the island: open just enough to take the drop

    var isOpen: Bool { self != .collapsed }
}

enum ShelfSection: String, CaseIterable, Identifiable {
    case files = "Files"
    case screenshots = "Screenshots"
    var id: Self { self }
}

/// The island's modules, in the order of the tab bar (the M3 hub design's order).
enum IslandTab: String, CaseIterable, Identifiable {
    case calendar = "Calendar"
    case clipboard = "Clipboard"
    case notes = "Notes and Tasks"
    case focus = "Focus"
    case music = "Now Playing"
    case shelf = "Shelf"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .clipboard: "list.clipboard"
        case .notes: "checklist"
        case .focus: "timer"
        case .music: "music.note"
        case .shelf: "tray"
        }
    }
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
    var tab: IslandTab = .music {
        didSet { if tab != oldValue { relayout() } }
    }
    var shelfSection: ShelfSection = .files {
        didSet { if shelfSection != oldValue { relayout() } }
    }
    /// The screenshot grid gets a taller panel; everything else keeps the compact one.
    var wantsTallPanel: Bool { isTall(state) }
    /// What the island draws. Trails `wantsTallPanel` by one turn when growing, so the window is
    /// already tall when the shape starts to grow (see `relayout`).
    private(set) var showsTallPanel = false

    func isTall(_ state: IslandState) -> Bool {
        state == .pinned && tab == .shelf && shelfSection == .screenshots
    }
    var geometry = IslandGeometry.fallback
    var hoverOpens = true
    let demo: DemoMediaProvider
    let media: MediaCoordinator
    let shelf: ShelfModel
    let library: ScreenshotLibrary
    let calendar: CalendarModule
    let clipboard: ClipboardModule
    let notes: NotesModule
    let focus: FocusModule
    /// Whether the drag over the island carries something the shelf can take.
    private(set) var dropIsValid = true
    /// Where a drop will go: the screenshot library if it is what's on screen, else the File Shelf.
    private(set) var dropGoesToScreenshots = false

    init(providers: [any MediaProvider] = [], shelf: ShelfModel = ShelfModel(),
         library: ScreenshotLibrary = ScreenshotLibrary(store: ScreenshotStore(
             directory: FileManager.default.temporaryDirectory.appending(path: "orilio-unused-library"))),
         calendar: CalendarModule = CalendarModule(source: NoCalendarSource(), reminders: NoReminders(),
                                                   defaults: UserDefaults(suiteName: "orilio.unused") ?? .standard),
         clipboard: ClipboardModule = ClipboardModule(
             store: ClipboardStore(directory: FileManager.default.temporaryDirectory.appending(path: "orilio-unused-clipboard")),
             defaults: UserDefaults(suiteName: "orilio.unused") ?? .standard),
         notes: NotesModule = NotesModule(store: NotesStore(
             directory: FileManager.default.temporaryDirectory.appending(path: "orilio-unused-notes"))),
         focus: FocusModule = FocusModule(defaults: UserDefaults(suiteName: "orilio.unused") ?? .standard)) {
        let showDemo = UserDefaults.standard.bool(forKey: SettingsKeys.showDemoSource)
        demo = DemoMediaProvider(enabled: showDemo)
        media = MediaCoordinator(providers: providers + [demo])
        self.shelf = shelf
        self.library = library
        self.calendar = calendar
        self.clipboard = clipboard
        self.notes = notes
        self.focus = focus
    }

    /// A meeting about to start, for the collapsed island (only when Calendar is on and readable).
    var meetingSoon: CalendarEvent? {
        guard calendar.status == .ready else { return nil }
        return calendar.dayNow().soon()
    }

    /// Wider than the notch only while something live is shown: a focus session (340 pt) wins over
    /// a meeting about to start (412 pt), as in the design.
    var liveCollapsedWidth: CGFloat? {
        if focus.isActive { return IslandGeometry.focusWidth }
        return meetingSoon == nil ? nil : IslandGeometry.meetingWidth
    }

    /// Same state, new size (the Screenshots grid wants more room): let the window follow.
    /// Window first, shape second, as in `set`: if both changed in one update, SwiftUI would
    /// animate the root view's size with the shape and the island would slide down inside the
    /// taller window. Tabs and sections also change without `withAnimation` (their views animate
    /// through `.animation(_:value:)`), so the window resize never runs inside an animated update.
    private func relayout() {
        guard state.isOpen else { return }
        let tall = isTall(state)
        onWillChangeState?(state) // grows the window now, or shrinks it after the animation
        if tall, !showsTallPanel {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showsTallPanel = self.isTall(self.state)
            }
        } else {
            showsTallPanel = tall
        }
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
        dropGoesToScreenshots = state == .pinned && tab == .shelf && shelfSection == .screenshots
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
        let accepted: Bool
        if dropGoesToScreenshots {
            if case .unsupported = content { accepted = false } else { accepted = true }
            library.accept(content, receivingInto: shelf.receivedDirectory.deletingLastPathComponent().appending(path: "Incoming"))
        } else {
            accepted = shelf.accept(content, sequence: sequence)
        }
        dropGoesToScreenshots = false
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
        showsTallPanel = isTall(new)
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
