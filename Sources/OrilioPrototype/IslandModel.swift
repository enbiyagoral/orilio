// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation

enum IslandState: Equatable {
    case collapsed
    case expanded // hover: the full panel, without the keyboard; closes when the pointer leaves
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
    // The M4 Settings design's order; Camera Mirror is off until the user turns it on.
    case calendar = "Calendar"
    case focus = "Focus"
    case music = "Now Playing"
    case clipboard = "Clipboard"
    case notes = "Notes and Tasks"
    case shelf = "Shelf"
    case mirror = "Camera Mirror"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .clipboard: "list.clipboard"
        case .notes: "checklist"
        case .focus: "timer"
        case .music: "music.note"
        case .shelf: "tray"
        case .mirror: "camera"
        }
    }
}

enum SettingsKeys {
    /// Before M5.3; now `Preferences.openOnHover`.
    static let openOnHover = "openOnHover"
    static let preferNotchedDisplay = "preferNotchedDisplay"
}

/// Single source of truth for the island. The window controller only reacts to `onWillChangeState`.
@MainActor @Observable
final class IslandModel {
    // Debounce: a pointer passing over the island shouldn't open it; a brief slip outside shouldn't close it.
    static let closeDelay: Duration = .milliseconds(350)
    // Open is soft with a touch of overshoot; close is quicker and settles without bounce.
    static let openDuration = 0.5
    static let closeDuration = 0.3

    private(set) var state: IslandState = .collapsed
    var tab: IslandTab = .music {
        didSet {
            guard tab != oldValue else { return }
            if tab == .mirror { tabBeforeMirror = oldValue }
            relayout()
            updateMirror()
        }
    }
    /// Where the island goes back to when the mirror closes.
    @ObservationIgnored private var tabBeforeMirror: IslandTab?
    var shelfSection: ShelfSection = .files {
        didSet { if shelfSection != oldValue { relayout() } }
    }
    /// The screenshot grid gets a taller panel; everything else keeps the compact one.
    var wantsTallPanel: Bool { isTall(state) }
    /// What the island draws. Trails `wantsTallPanel` by one turn when growing, so the window is
    /// already tall when the shape starts to grow (see `relayout`).
    private(set) var showsTallPanel = false
    /// The mirror's panel as drawn; like `showsTallPanel`, it trails the window by a turn when growing.
    private(set) var shownCustomPanel: CGSize?

    /// The first-run flow, while it is on screen.
    private(set) var onboarding: OnboardingModel?
    /// After the flow: the one-time "Orilio lives here now" hint under the notch.
    private(set) var showsLivesHereHint = false
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    static let quickLookHeight: CGFloat = 560

    /// Shows the first-run flow in this island (first launch, or "Replay onboarding").
    func startOnboarding(defaults: UserDefaults = .standard, loginStatus: LoginItem.Status = LoginItem.status) {
        hintTask?.cancel()
        showsLivesHereHint = false
        onboarding = OnboardingModel(modules: modules, defaults: defaults, loginStatus: loginStatus)
        if state == .pinned { relayout() } else { set(.pinned) } // pinned: the island takes the keyboard
    }

    /// Ends the flow with the current choices (Done, Esc, the close button) and shows the hint.
    func finishOnboarding() {
        guard let onboarding else { return }
        onboarding.finish()
        self.onboarding = nil
        if !modules.isVisible(tab) { tab = modules.visible[0] }
        set(.collapsed)
        showsLivesHereHint = true
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.showsLivesHereHint = false
        }
    }

    /// The open island's size while it shows the mirror (the M4.1 design's card or mirror), the
    /// first-run flow (the M5 design's 760 × 480) or a Shelf file in Quick Look (560 pt tall).
    func customPanel(for state: IslandState) -> CGSize? {
        if state == .pinned, tab == .shelf, shelfSection == .files, shelf.previewing != nil {
            let room = geometry.usableHeight + geometry.topInset - IslandGeometry.shadowMargin * 2
            return CGSize(width: geometry.panelWidth, height: min(Self.quickLookHeight, max(geometry.full.height, room)))
        }
        if onboarding != nil, state.isOpen { return OnboardingModel.panelSize }
        guard state.isOpen, state != .dropTarget, tab == .mirror else { return nil }
        if state == .expanded { return mirror.panelSize(scale: geometry.panelWidth / IslandGeometry.fullWidth, hoverCard: true) }
        return mirror.panelSize(scale: geometry.panelWidth / IslandGeometry.fullWidth)
    }

    /// The camera runs only in an island the user opened (a click, not a hover) on the mirror.
    private func updateMirror() {
        mirror.setVisible(state == .pinned && tab == .mirror)
    }
    func isTall(_ state: IslandState) -> Bool {
        (state == .pinned || state == .expanded) && tab == .shelf && shelfSection == .screenshots
    }
    var geometry = IslandGeometry.fallback
    var hoverOpens = true
    /// Settings › General › Hover delay.
    @ObservationIgnored var hoverDelay: Duration = .milliseconds(90)
    let media: MediaCoordinator
    let shelf: ShelfModel
    let library: ScreenshotLibrary
    let calendar: CalendarModule
    let clipboard: ClipboardModule
    let notes: NotesModule
    let focus: FocusModule
    let modules: ModuleSettings
    let live: LiveActivityCoordinator
    /// Whether the drag over the island carries something the shelf can take.
    private(set) var dropIsValid = true
    /// How many items the drag over the island carries ("Release to add 3 files").
    private(set) var dropCount = 1
    /// A file drag is under way somewhere on screen: the collapsed island glows ("Drop on Shelf").
    /// The window follows it like the live width (see `IslandWindowController.followLiveWidth`).
    var dropHint = false
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
         focus: FocusModule = FocusModule(defaults: UserDefaults(suiteName: "orilio.unused") ?? .standard),
         modules: ModuleSettings = ModuleSettings(defaults: UserDefaults(suiteName: "orilio.unused") ?? .standard),
         live: LiveActivityCoordinator = LiveActivityCoordinator(),
         mirror: CameraMirrorModel? = nil,
         sharing other: IslandModel? = nil) {
        self.mirror = mirror ?? other?.mirror ?? CameraMirrorModel(defaults: UserDefaults(suiteName: "orilio.unused") ?? .standard,
                                                                     observeSystem: false)
        // Another display's island shows the same music; only its open state is its own.
        if let other {
            media = other.media
        } else {
            media = MediaCoordinator(providers: providers)
        }
        self.shelf = shelf
        self.library = library
        self.calendar = calendar
        self.clipboard = clipboard
        self.notes = notes
        self.focus = focus
        self.modules = modules
        self.live = live
        if !modules.isVisible(tab) { tab = modules.visible[0] }
        modules.whenHidden { [weak self] in self?.moduleHidden($0) }
        self.mirror.whenChanged { [weak self] in self?.relayout() } // card → live mirror changes the size
        self.mirror.whenMustClose { [weak self] in if self?.tab == .mirror { self?.dismiss() } }
    }

    let mirror: CameraMirrorModel

    /// A hidden module stops its work, so nothing runs (or reads) for a module the user removed.
    /// Nothing stored is deleted: showing it again brings it back as it was, turned off.
    private func moduleHidden(_ module: IslandTab) {
        switch module {
        case .calendar: calendar.disable()
        case .clipboard: if clipboard.status == .on { clipboard.pause() }
        case .focus: focus.reset()
        case .mirror: mirror.setVisible(false)
        case .notes, .music, .shelf: break
        }
        if tab == module { tab = modules.visible[0] }
    }

    /// What the collapsed island's ears show (see `LiveActivityResolver` for the order). Derived
    /// from the modules' observable state, so it changes only when they do.
    var earLayout: EarLayout {
        let playing = media.current.flatMap { $0.state == .playing ? $0 : nil }
        return LiveActivityResolver.layout(meeting: meetingSoon, focus: FocusEarKind(focus), transient: live.transient,
                                           nowPlaying: playing, visible: modules.visibleSet, indicators: modules.indicators)
    }

    /// A meeting about to start, for the collapsed island (only when Calendar is on and readable),
    /// or the debug stand-in.
    var meetingSoon: CalendarEvent? {
        guard calendar.status == .ready else { return nil }
        return calendar.dayNow().soon(within: calendar.meetingLead)
    }

    /// The notch plus two ears sized for their content, or nil when idle (the notch alone).
    var liveCollapsedWidth: CGFloat? {
        earLayout.collapsedWidth(notch: geometry.notchWidth, pill: IslandGeometry.pillWidth, now: Date())
    }

    /// The trailing ear's Join. The debug stand-in has nowhere to go.
    func join(_ event: CalendarEvent) {
        calendar.join(event)
    }

    /// Same state, new size (the Screenshots grid wants more room): let the window follow.
    /// Window first, shape second, as in `set`: if both changed in one update, SwiftUI would
    /// animate the root view's size with the shape and the island would slide down inside the
    /// taller window. Tabs and sections also change without `withAnimation` (their views animate
    /// through `.animation(_:value:)`), so the window resize never runs inside an animated update.
    func relayout() {
        guard state.isOpen else { return }
        let tall = isTall(state)
        let panel = customPanel(for: state)
        onWillChangeState?(state) // grows the window now, or shrinks it after the animation
        if tall, !showsTallPanel {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showsTallPanel = self.isTall(self.state)
            }
        } else {
            showsTallPanel = tall
        }
        if let panel, panel.width > (shownCustomPanel?.width ?? 0) || panel.height > (shownCustomPanel?.height ?? 0) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.shownCustomPanel = self.customPanel(for: self.state)
            }
        } else {
            shownCustomPanel = panel
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
        if inside { autoClose?.cancel() } // the user came to look: the focus card stays
        if inside, showsLivesHereHint {
            hintTask?.cancel()
            showsLivesHereHint = false // the hint goes on the first hover
        }
        if inside, state == .collapsed, hoverOpens {
            schedule(.expanded, after: hoverDelay, choosingTab: true)
        } else if !inside, state == .expanded {
            schedule(.collapsed, after: Self.closeDelay)
        }
    }

    /// A click anywhere on the island (outside its buttons) opens the full controller.
    /// A click on the collapsed island opens the module of what it shows, else the default one.
    func tap() {
        if showWhatsNewIfPending() { return }
        if !state.isOpen { chooseOpeningTab() }
        set(.pinned)
    }

    /// After a feature update, the first click on the island opens What's New (once).
    static var pendingWhatsNew: WhatsNew?

    private func showWhatsNewIfPending() -> Bool {
        guard let notes = Self.pendingWhatsNew, onboarding == nil else { return false }
        Self.pendingWhatsNew = nil
        WhatsNewGate.markShown(AboutPane.version, defaults: .standard)
        WhatsNewWindow.show(notes)
        return true
    }

    // MARK: Keyboard (the M5 Keyboard design)

    /// Opened with the shortcut: the panel takes the keyboard, the main action wears a focus ring
    /// and the hint bar shows. A click inside ends it; hover never sets it.
    private(set) var keyboardOpened = false
    /// ⌘ held for 400 ms: the module tabs show their numbers.
    private(set) var showsModuleBadges = false
    @ObservationIgnored private var commandHold = CommandHold()
    @ObservationIgnored private var badgeTask: Task<Void, Never>?

    func openFromKeyboard() {
        tap()
        keyboardOpened = true
    }

    func pointerUsed() { if keyboardOpened { keyboardOpened = false } }

    /// The modifier keys changed while the island is key.
    func modifiersChanged(commandOnly: Bool) {
        commandHold.changed(commandOnly: commandOnly, at: ProcessInfo.processInfo.systemUptime)
        badgeTask?.cancel()
        guard commandOnly else { return showsModuleBadges = false }
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CommandHold.delay))
            guard !Task.isCancelled, let self else { return }
            self.showsModuleBadges = self.commandHold.showsBadges(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// A key while the island is key. Returns false when it isn't the island's.
    func handleKey(_ key: KeyPress, editing: IslandKeyRouter.Editing) -> Bool {
        commandHold.cancel() // ⌘ plus a key is a shortcut, not a hold
        badgeTask?.cancel()
        showsModuleBadges = false
        guard state == .pinned, let action = IslandKeyRouter.route(key, tab: tab, editing: editing) else { return false }
        return perform(action)
    }

    @discardableResult
    func perform(_ action: IslandKeyAction) -> Bool {
        switch action {
        case .module(let index):
            let visible = modules.visible
            guard visible.indices.contains(index) else { return false }
            tab = visible[index]
        case .adjacentModule(let step):
            selectAdjacentTab(step)
        case .move(let step):
            switch tab {
            case .clipboard: clipboard.moveSelection(by: step)
            case .shelf: shelf.moveSelection(by: step)
            case .notes: notes.moveTaskSelection(by: step)
            default: return false
            }
        case .primary:
            return performPrimary()
        case .preview:
            return shelf.handleKey(keyCode: 49, command: false)
        case .pinItem:
            guard let item = clipboard.selectedItem else { return false }
            clipboard.togglePin(item)
        case .deleteItem:
            switch tab {
            case .clipboard:
                guard let item = clipboard.selectedItem else { return false }
                clipboard.moveSelection(by: 1)
                if clipboard.selectedID == item.id { clipboard.moveSelection(by: -1) }
                clipboard.remove(item)
            case .shelf: return shelf.handleKey(keyCode: 51, command: false)
            case .notes:
                guard let task = notes.visibleTasks.first(where: { $0.id == notes.selectedTaskID }) else { return false }
                notes.deleteTask(task)
            default: return false
            }
        case .search: clipboard.requestSearch()
        case .type(let text):
            if tab == .notes { notes.requestEditor(typing: text) } else { clipboard.requestSearch(typing: text) }
        case .settings: SettingsWindow.show()
        case .togglePin: togglePin()
        case .close:
            if tab == .shelf, shelf.previewing != nil { shelf.closePreview() } else { dismiss() }
        case .closeAndUnpin: dismiss()
        }
        return true
    }

    /// ⏎: the module's main action.
    private func performPrimary() -> Bool {
        switch tab {
        case .calendar:
            let day = calendar.dayNow()
            guard let event = meetingSoon ?? day.timed.first(where: { $0.meeting != nil && $0.end > day.now }) else { return false }
            join(event)
        case .focus:
            switch focus.finished {
            case .session?: focus.startBreak()
            case .breakOver?: focus.begin()
            case nil: focus.toggle()
            }
        case .music:
            guard let current = media.current else { return false }
            Task { try? await media.send(.togglePlayPause, to: current.sourceID) }
        case .clipboard:
            guard let item = clipboard.selectedItem ?? clipboard.visibleItems.first else { return false }
            Task { await clipboard.copy(item) }
        case .shelf:
            let selected = shelf.items.filter { shelf.selection.contains($0.id) }
            guard !selected.isEmpty else { return false }
            shelf.open(selected)
        case .notes:
            guard let task = notes.visibleTasks.first(where: { $0.id == notes.selectedTaskID }) else { return false }
            notes.toggle(task)
        case .mirror:
            return false
        }
        return true
    }

    // MARK: Focus end

    /// The one time Focus interrupts: the island opens by itself on the session-done (or
    /// break-over) card without taking the keyboard, and closes after 8 s if ignored.
    func presentFocusEnd() {
        guard modules.isVisible(.focus), onboarding == nil else { return }
        tab = .focus
        if !state.isOpen {
            pinTakesFocus = false
            set(.pinned)
            pinTakesFocus = true
        }
        autoClose?.cancel()
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: Self.focusEndShown)
            guard !Task.isCancelled, let self, self.state == .pinned, self.tab == .focus else { return }
            self.set(.collapsed) // the card goes; the ear keeps "Session done" until the user acts
        }
    }

    static let focusEndShown: Duration = .seconds(8)
    @ObservationIgnored private var autoClose: Task<Void, Never>?

    /// A click inside the hover panel: keep it open, on the module it shows.
    func keepOpen() {
        autoClose?.cancel()
        guard state == .expanded else { return }
        pinnedByClick = Date()
        set(.pinned)
    }

    @ObservationIgnored private var pinnedByClick: Date?

    /// The next or previous visible module, wrapping around.
    func selectAdjacentTab(_ offset: Int) {
        let visible = modules.visible
        guard let index = visible.firstIndex(of: tab) else { tab = visible[0]; return }
        tab = visible[(index + offset + visible.count) % visible.count]
    }

    /// Hover and clicks open to the module that is live, else the default one.
    private func chooseOpeningTab() { tab = openingTab }

    /// Settings › Modules › "When the island opens, show".
    private var openingTab: IslandTab {
        switch modules.openWith {
        case .live: earLayout.primary?.module ?? tab
        case .last: tab
        case .first: modules.visible[0]
        }
    }

    /// A click on one ear of the collapsed island opens that ear's module.
    func tapEar(_ side: EarSide) {
        guard !state.isOpen else { return tap() }
        if showWhatsNewIfPending() { return }
        if case .transient(let transient)? = earLayout.activity(at: side)?.payload, let action = transient.action {
            live.clearTransient()
            switch action {
            case .restartToUpdate: UpdateModel.shared.install()
            case .showUpdates: SettingsWindow.show(pane: .updates)
            }
            return
        }
        tab = earLayout.activity(at: side)?.module ?? openingTab
        set(.pinned)
    }
    func togglePin() {
        // The click on the pin button already pinned the hover panel (`keepOpen`); it means "pin".
        if let pinned = pinnedByClick, Date().timeIntervalSince(pinned) < 0.6 {
            pinnedByClick = nil
            return
        }
        set(state == .pinned ? .expanded : .pinned)
    }
    func dismiss() {
        if onboarding != nil { return finishOnboarding() } // never a half state
        set(.collapsed)
    }

    // MARK: Dragging onto the island

    func dragEntered(valid: Bool, count: Int = 1) {
        dropIsValid = valid && modules.isVisible(.shelf) // a hidden Shelf takes nothing
        dropCount = count
        dropHint = false
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
        if !new.isOpen {
            shelf.closePreview() // Quick Look closes with the island
            keyboardOpened = false
            showsModuleBadges = false
        }
        if !state.isOpen, new.isOpen {
            media.refreshAll()
            if modules.store.value.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        state = new
        showsTallPanel = isTall(new)
        shownCustomPanel = customPanel(for: new)
        updateMirror()
        // Closing the mirror goes back to the module before it.
        if new == .collapsed, tab == .mirror {
            tab = tabBeforeMirror.flatMap { modules.isVisible($0) && $0 != .mirror ? $0 : nil }
                ?? modules.visible.first { $0 != .mirror } ?? tab
        }
    }

    /// The menu bar's "Mirror": open the island straight to the camera mirror.
    func openMirror() {
        guard modules.isVisible(.mirror) else { return }
        tab = .mirror
        set(.pinned)
    }

    private func schedule(_ target: IslandState, after delay: Duration, choosingTab: Bool = false) {
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if target == .collapsed, self.isPointerBusy() {
                self.schedule(target, after: delay) // check again once the user lets go
            } else {
                if choosingTab { self.chooseOpeningTab() }
                self.set(target)
            }
        }
    }
}
