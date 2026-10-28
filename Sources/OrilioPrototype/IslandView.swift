import AppKit
import SwiftUI

/// Orilio's accent: a neon green that stays readable as text and controls on the black island.
private let coverGradient = LinearGradient(
    colors: [Color(red: 0.96, green: 0.78, blue: 0.68), Color(red: 0.96, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.27, blue: 0.56)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

// Radii are concentric: outer = inner + padding (14 + 18 = 32 for the panel, 10 + 12 = 22 for the preview).
enum Metrics {
    static let padding: CGFloat = 18
    static let innerRadius: CGFloat = 14
    static let openRadius: CGFloat = 36 // the design's panel radius
    static let previewPadding: CGFloat = 12
    static let previewInnerRadius: CGFloat = 10
    static let previewRadius: CGFloat = previewPadding + previewInnerRadius
    static let collapsedRadius: CGFloat = 10
    /// Lowest text opacity on black that still meets 4.5:1 contrast.
    static let secondaryText = 0.6
}

/// Notch-like silhouette: concave ears at the top corners melt it into the screen edge,
/// rounded bottom corners. Both radii animate, so the shape morphs instead of cross-fading.
extension EnvironmentValues {
    /// Under a notch, or floating (see `IslandGeometry.layout`).
    @Entry var islandLayout = IslandLayout.notch
}

struct IslandShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat
    /// Above 0, the shape floats this far below the top with all four corners rounded (no notch).
    var floatTop: CGFloat = 0
    /// Floating and collapsed: the capsule also stays this far above the window's bottom.
    var floatBottom: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { (ear, bottom) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        if floatTop > 0 {
            let panel = CGRect(x: rect.minX, y: rect.minY + floatTop, width: rect.width, height: rect.height - floatTop - floatBottom)
            return Path(roundedRect: panel, cornerRadius: min(bottom, panel.height / 2), style: .continuous)
        }
        let e = ear
        let b = min(bottom, (rect.width - 2 * e) / 2, rect.height - e)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e + b, y: rect.maxY), control: CGPoint(x: rect.minX + e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - b), control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Content arrives slightly after the shape starts growing: out of a blur, a hair smaller, anchored to the top.
private struct Reveal: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 8)
            .scaleEffect(shown ? 1 : 0.94, anchor: .top)
    }
}

private extension AnyTransition {
    static func reveal(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: Reveal(shown: false), identity: Reveal(shown: true))
    }
}

struct IslandView: View {
    let model: IslandModel
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let geometry = model.geometry
        let state = model.state
        let open = state.isOpen
        let hint = model.dropHint && state == .collapsed
        let size = geometry.size(for: state, tall: model.showsTallPanel, collapsedWidth: model.liveCollapsedWidth,
                                 panel: model.shownCustomPanel, dropHint: hint)
        let floats = geometry.layout == .floating
        let ear = open && !floats ? IslandGeometry.earRadius : 0
        let radius = switch state {
        case .collapsed: floats ? size.height / 2 : hint ? 18 : Metrics.collapsedRadius // the M5 Moments design's drop hint
        case .dropTarget: floats ? IslandGeometry.floatingRadius : CGFloat(30) // the M5 Moments design
        case .expanded, .pinned:
            model.onboarding != nil ? OnboardingModel.radius : floats ? IslandGeometry.floatingRadius : Metrics.openRadius
        }
        // Floating (no notch): the capsule sits inside the menu bar band; the open panel starts below it.
        let shape = IslandShape(ear: ear, bottom: radius,
                                floatTop: floats ? (open ? geometry.openTop : IslandGeometry.pillInset) : 0,
                                floatBottom: floats && !open ? IslandGeometry.pillInset : 0)

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                // The no-notch design's hairline edge: 0.5 pt of 22% white.
                .overlay(shape.stroke(.white.opacity(floats ? 0.22 : 0), lineWidth: 0.5))
                // A file drag somewhere on screen: a 1.5 pt mint edge ("Drop on Shelf").
                .overlay(shape.stroke(accent(.action).opacity(hint ? 0.6 : 0), lineWidth: 3)) // the outer half falls outside the window
                // The design's 0 24 60 rgba(0,0,0,.55), kept inside the window's shadow margin.
                .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 18, y: 14)

            ZStack(alignment: .top) {
                switch state {
                case .pinned, .expanded:
                    // With a notch the header shares the notch's row, so content starts at the very top;
                    // floating, it starts inside the panel.
                    ExpandedContent(model: model)
                        .padding(.top, geometry.openTop)
                        .padding(.horizontal, ear)
                        .transition(contentTransition)
                case .dropTarget:
                    DropTargetView(valid: model.dropIsValid, count: model.dropCount,
                                   destination: model.dropGoesToScreenshots ? "Screenshots" : "Shelf")
                        .padding(.top, floats ? geometry.openTop + 12 : geometry.topInset)
                        .padding(.horizontal, ear)
                        .transition(contentTransition)
                case .collapsed:
                    let layout = model.earLayout
                    Group {
                        if hint {
                            Text("Drop on Shelf")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(accent(.action))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, 10)
                        } else if !layout.isIdle {
                            CollapsedEars(layout: layout, model: model)
                        } else if !geometry.hasNotch, model.modules.isVisible(.music), model.modules.indicators.contains(.music) {
                            // Without a notch the pill is always there; it shows a paused track.
                            CompactPill(media: model.media)
                        }
                    }
                    // Content cross-fades; the width springs (see `.animation` below).
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
            .clipShape(shape)
        }
        .frame(width: size.width + 2 * ear, height: size.height)
        .contentShape(shape)
        // A click on an ear opens that ear's module; elsewhere (outside buttons) the live one.
        .onTapGesture(coordinateSpace: .local) { location in
            guard state != .pinned else { return }
            if state == .collapsed {
                model.tapEar(location.x < (size.width + 2 * ear) / 2 ? .leading : .trailing)
            } else {
                model.tap()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orilio island")
        .accessibilityAction(named: "Open controls") { model.tap() }
        .animation(shapeAnimation(collapsing: state == .collapsed), value: state)
        // One spring when the collapsed island widens or narrows for what it shows.
        .animation(Theme.current.spring(duration: 0.44, bounce: 0.15), value: state == .collapsed ? size.width : 0)
        .animation(Theme.current.spring(duration: 0.3, bounce: 0.15), value: hint)
        // The Screenshots grid makes the open panel taller without a state change: grow and shrink
        // the same way (the window keeps its larger size until the shrink has finished).
        .animation(shapeAnimation(collapsing: !model.showsTallPanel), value: model.showsTallPanel)
        // Outside the animation on purpose: the window resizes instantly and the island must stay
        // pinned to the top edge, not glide from its old position.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.reducesMotion, Theme.current.reducesMotion)
        .environment(\.islandLayout, geometry.layout)

    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .reveal(reduceMotion).animation(
                reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0).delay(0.08)),
            // Leaving content gets out of the way before the shape changes under it.
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private func shapeAnimation(collapsing: Bool) -> Animation? {
        // Springs are interruptible: hovering back mid-close retargets from where the shape is.
        collapsing
            ? Theme.current.spring(duration: IslandModel.closeDuration)
            : Theme.current.spring(duration: IslandModel.openDuration, bounce: 0.22)
    }
}

private struct CompactPill: View {
    let media: MediaCoordinator

    var body: some View {
        HStack(spacing: 8) {
            if let session = media.current {
                Artwork(seed: session.title, url: session.artworkURL, size: 16, radius: 5)
                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                ActivityIndicator(session: session)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

/// Music gets the moving bars; video gets a still glyph, since the picture itself is the activity.
private struct ActivityIndicator: View {
    let session: MediaSessionSnapshot
    var expectedPlaying: Bool? = nil

    var body: some View {
        if session.kind == .video {
            let playing = expectedPlaying ?? (session.state == .playing)
            Image(systemName: playing ? "play.rectangle.fill" : "pause.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent(.live).opacity(playing ? 1 : 0.5))
                .accessibilityHidden(true)
        } else {
            EqualizerView(mode: EqualizerView.Mode(session, expectedPlaying: expectedPlaying), color: NSColor(accent(.live)))
        }
    }
}

private struct ExpandedContent: View {
    @Bindable var model: IslandModel
    @Environment(\.islandLayout) private var layout
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        if let onboarding = model.onboarding {
            OnboardingView(model: onboarding, floating: layout == .floating) { model.finishOnboarding() }
                .transition(.opacity)
        } else if model.tab == .mirror {
            // The M4.1 design: the mirror has its own header ("Mirror" and close), no tab bar.
            MirrorView(mirror: model.mirror, hoverOnly: model.state == .expanded) { model.dismiss() }
                .transition(.opacity)
        } else {
            hub
        }
    }

    private var hub: some View {
        VStack(spacing: 0) {
            // 38 pt header: tabs left of the notch, pin and close right of it (M3 hub design).
            HStack(spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(Array(model.modules.visible.enumerated()), id: \.element) { index, tab in
                        ModuleTab(tab: tab, selected: model.tab == tab, live: isLive(tab),
                                  badge: model.showsModuleBadges && index < 6 ? index + 1 : nil) { model.tab = tab }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Modules")
                Spacer()
                if layout == .floating, !model.geometry.displayName.isEmpty {
                    // No notch to place the island by: the panel says which display it's on.
                    Text(model.geometry.displayName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1).padding(.trailing, 6)
                }
                HeaderButton(symbol: model.state == .pinned ? "pin.fill" : "pin", label: "Keep island open",
                             active: model.state == .pinned) { model.togglePin() }
                HeaderButton(symbol: "xmark", label: "Close island (Esc)", active: false) { model.dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(height: model.geometry.headerRow)

            ZStack {
                switch model.tab {
                case .calendar: CalendarPanel(module: model.calendar)
                case .clipboard: ClipboardPanel(module: model.clipboard, library: model.library)
                case .notes: NotesPanel(module: model.notes)
                case .focus: FocusPanel(module: model.focus)
                case .music: MusicCard(media: model.media)
                case .shelf: ShelfView(shelf: model.shelf, library: model.library, section: $model.shelfSection,
                                       draggedOut: { model.dismiss() })
                    // Quick Look grows the island to 560 pt and back (see `IslandModel.customPanel`).
                    .onChange(of: model.shelf.previewing) { model.relayout() }
                case .mirror: EmptyView() // drawn without the hub (see `body`)
                }
            }
            .id(model.tab)
            .transition(.reveal(reduceMotion))
            // Music lays out its own padding around a full-width glow.
            .padding(model.tab == .music ? EdgeInsets() : EdgeInsets(top: 10, leading: 20, bottom: 20, trailing: 20))
            .frame(maxHeight: .infinity, alignment: .top)
            // Holding ⌘: the content dims so the tab numbers read first.
            .opacity(model.showsModuleBadges ? 0.45 : 1)
        }
        .overlay(alignment: .bottom) {
            if model.keyboardOpened { KeyHintBar(tab: model.tab).transition(.opacity) }
        }
        .environment(\.keyboardFocusVisible, model.keyboardOpened)
        .animation(.easeOut(duration: 0.15), value: model.showsModuleBadges)
        .animation(.easeOut(duration: 0.15), value: model.keyboardOpened)
        .animation(Theme.current.spring(duration: 0.3, bounce: 0.1), value: model.tab)
    }

    /// A small dot on a tab that has something live while another tab is shown.
    private func isLive(_ tab: IslandTab) -> Bool {
        guard model.tab != tab else { return false }
        switch tab {
        case .calendar: return model.meetingSoon != nil
        case .music: return model.media.current?.state == .playing
        case .focus: return model.focus.isRunning
        case .clipboard, .notes, .shelf, .mirror: return false // the mirror never claims attention
        }
    }
}

/// A 32 × 28 icon tab (radius 9): white on a 14% plate when selected, 55% white otherwise.
private struct ModuleTab: View {
    let tab: IslandTab
    let selected: Bool
    let live: Bool
    /// ⌘ held: the tab's number under it (the M5 Keyboard design's 20 pt white badge).
    var badge: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                .frame(width: 32, height: 28)
                .background(selected ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if live {
                        Circle().fill(accent(.live)).frame(width: 5, height: 5)
                            .themeGlow(.live, radius: 3, opacity: 1)
                            .padding(.top, 4).padding(.trailing, 5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .top) {
            if let badge {
                Text("\(badge)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 4)
                    .offset(y: 22)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(badge == nil ? 0 : 1)
        .help(tab.rawValue)
        .accessibilityLabel(tab.rawValue)
        .accessibilityValue(live ? "Active" : "")
        .accessibilityHint("Control-Tab moves between modules")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Pin and close: 30 × 28, radius 9; the pin turns accent-colored on a plate when active.
private struct HeaderButton: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? accent(.rest) : .white.opacity(0.6))
                .frame(width: 30, height: 28)
                .background(active ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Real cover art when the source has it, otherwise a gradient tinted per title.
/// Decoding happens in `ArtworkCache`; a new track's cover cross-fades in, and the previous
/// track's cover is never shown for the new one.
private struct Artwork: View {
    let seed: String
    var url: URL? = nil
    let size: CGFloat
    let radius: CGFloat
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(coverGradient).hueRotation(.degrees(hue))
            if let loaded, loaded.url == url {
                Image(decorative: loaded.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(loaded.url)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(.easeInOut(duration: 0.25), value: loaded?.url)
        .task(id: url) {
            guard let url else { return }
            let cover = await ArtworkCache.shared.image(for: url)
            guard !Task.isCancelled, let cover else { return } // the track changed while loading
            loaded = (url, cover.image)
        }
    }
}

private struct MusicCard: View {
    @Environment(\.islandLayout) private var layout
    let media: MediaCoordinator
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let access = PlayerAccess.shared
        let session = media.current
        let state = NowPlayingCardState.resolve(
            sessionApp: session.flatMap { PlayerAccess.isScriptable($0.providerID) ? $0.providerID : nil },
            access: session.flatMap { access.access($0.providerID, statuses: media.statuses) },
            declined: session.map { access.declined($0.providerID) } ?? false,
            revokedApps: media.statuses.filter { $0.value == .permissionDenied }.keys.sorted().map(media.providerName),
            spotifyInstalled: PlayerAccess.installed(.spotify), musicInstalled: PlayerAccess.installed(.music),
            hasSession: session != nil)
        ZStack {
            switch state {
            case .session(let ask):
                if let ask, let session {
                    let name = media.providerName(ask)
                    StatusCard(tone: .ask(tile: MusicEar.warm.opacity(0.16), ink: MusicEar.warm), symbol: "music.note",
                               title: "Let Orilio control \(name)?",
                               detail: "Needed for play, pause and skip from \(layout.place). macOS asks once for each music app.",
                               primary: .init("Continue") { Task { await media.requestControl(session.providerID) } },
                               secondary: .init("Not now") { access.decline(session.providerID) }, layout: .ask)
                        .padding(EdgeInsets(top: 10, leading: 20, bottom: 20, trailing: 20))
                } else if let session {
                    NowPlaying(session: session, media: media)
                        // A different source is a different card: cross-fade, and start with fresh control state.
                        .id(session.sourceID)
                        .transition(.opacity)
                }
            case .revoked(let app):
                StatusCard(tone: .warn, symbol: "exclamationmark.shield", title: "Orilio can no longer control \(app)",
                           detail: "Access was turned off. Re-enable it in Privacy & Security › Automation.",
                           primary: .init("Open System Settings") { PrivacyPane.open(PrivacyPane.automation) }, layout: .banner)
            case .nothingPlaying(let spotify, let music):
                StatusCard(tone: .empty, symbol: "music.note", title: "Nothing playing",
                           detail: "Start something and it shows up here.",
                           primary: spotify ? .init("Open Spotify") { PlayerAccess.open(.spotify) }
                               : music ? .init("Open Music") { PlayerAccess.open(.music) } : nil,
                           secondary: spotify && music ? .init("Open Music") { PlayerAccess.open(.music) } : nil)
                    .padding(EdgeInsets(top: 10, leading: 20, bottom: 20, trailing: 20))
            case .spotifyMissing:
                StatusCard(tone: .empty, symbol: "arrow.down.to.line", title: "Spotify isn’t installed",
                           detail: "Orilio works with Music too.", primary: .init("Use Music") { PlayerAccess.open(.music) })
                    .padding(EdgeInsets(top: 10, leading: 20, bottom: 20, trailing: 20))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: media.current?.sourceID)
    }
}

/// Automation access for the scriptable players, as Orilio knows it, and Not now per app.
@MainActor @Observable
final class PlayerAccess {
    static let shared = PlayerAccess()
    private var declinedApps: Set<String>
    private static let bundles = ["spotify": ScriptablePlayer.spotify.bundleID, "music": ScriptablePlayer.music.bundleID]

    private init() {
        declinedApps = Set(UserDefaults.standard.stringArray(forKey: "automation.askDeclined") ?? [])
    }

    static func isScriptable(_ providerID: String) -> Bool { bundles[providerID] != nil }

    /// Granted once an Apple Event got through (remembered by the provider), denied when macOS said no.
    func access(_ providerID: String, statuses: [String: MediaProviderStatus]) -> ControlAccess? {
        guard let bundle = Self.bundles[providerID] else { return nil }
        if statuses[providerID] == .permissionDenied { return .denied }
        return UserDefaults.standard.bool(forKey: "automationGranted.\(bundle)") ? .granted : .undetermined
    }

    func declined(_ providerID: String) -> Bool { declinedApps.contains(providerID) }

    /// Not now: playback info still shows; the controls ask again when used.
    func decline(_ providerID: String) {
        declinedApps.insert(providerID)
        UserDefaults.standard.set(declinedApps.sorted(), forKey: "automation.askDeclined")
    }

    static func installed(_ player: ScriptablePlayer) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) != nil
    }

    static func open(_ player: ScriptablePlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct NowPlaying: View {
    let session: MediaSessionSnapshot
    let media: MediaCoordinator
    /// Direction of the last skip the user asked for, for the title transition.
    @State private var step = 1
    @State private var feedback = ControlFeedback()
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let caps = session.capabilities
        let denied = media.statuses[session.providerID] == .permissionDenied
        // The M3 hub design: a 150 pt cover (radius 24) over its own blurred glow, a 22 pt title,
        // a 5 pt progress bar and centered white controls.
        HStack(spacing: 24) {
            ZStack {
                Artwork(seed: session.title, url: session.artworkURL, size: 126, radius: 26)
                    .blur(radius: 26)
                    .opacity(0.75)
                Artwork(seed: session.title, url: session.artworkURL, size: 150, radius: 24)
                    .overlay {
                        if session.artworkURL == nil {
                            Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(.black.opacity(0.4))
                        }
                    }
            }
            .frame(width: 150, height: 150)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(session.title.isEmpty ? "Unknown title" : session.title)
                                .font(.system(size: 22, weight: .semibold))
                                .tracking(-0.44)
                                .foregroundStyle(.white)
                                .truncationMode(.tail)
                            ActivityIndicator(session: session, expectedPlaying: feedback.expectedPlaying)
                        }
                        if let failure = feedback.failure {
                            Label(failure, systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.orange)
                                .transition(.opacity)
                        } else {
                            Text(subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(Metrics.secondaryText))
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(session.title)
                    // Next slides in from the right, previous from the left.
                    .transition(reduceMotion ? .opacity : .push(from: step > 0 ? .trailing : .leading))
                    .clipped()
                    SourceBadge(session: session, media: media)
                }

                ProgressRow(session: session,
                            onSeek: caps.contains(.seek) ? { run(.seek, .seek(to: $0)) } : nil)

                HStack(spacing: 22) {
                    if denied && !caps.contains(.playPause) {
                        // The design's "Control denied": playback info still shows; one way back.
                        HStack(spacing: 10) {
                            Label("Can’t control \(session.sourceName)", systemImage: "exclamationmark.shield")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(SettingsDesign.amber)
                            PermissionLink(text: "Fix in Settings")
                        }
                    } else {
                        // Unsupported controls stay in place, dimmed, so the layout doesn't jump between sources.
                        IconButton(symbol: "backward.fill", label: "Previous track", glyph: 20, frame: 44) { run(.skip, .previous, step: -1) }
                            .disabled(!caps.contains(.previous) || feedback.inFlight.contains(.skip))
                            .keyboardShortcut(.leftArrow, modifiers: .command)
                        PlayPauseButton(session: session, media: media, feedback: $feedback, diameter: 48, filled: false)
                            .keyboardShortcut(.space, modifiers: [])
                        IconButton(symbol: "forward.fill", label: "Next track", glyph: 20, frame: 44) { run(.skip, .next, step: 1) }
                            .disabled(!caps.contains(.next) || feedback.inFlight.contains(.skip))
                            .keyboardShortcut(.rightArrow, modifiers: .command)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 26, bottom: 20, trailing: 32))
        .frame(maxHeight: .infinity)
        // A warm glow behind the cover (the design's radial gradient).
        .background(RadialGradient(colors: [Color(red: 0.969, green: 0.71, blue: 0.431).opacity(0.18), .clear],
                                   center: UnitPoint(x: 0.14, y: 0.5), startRadius: 0, endRadius: 260))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Animate what the user can see change, not every heartbeat that refreshes the snapshot.
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1), value: session.title)
        .animation(.easeInOut(duration: 0.2), value: feedback.failure)
        .onChange(of: session.state) { feedback.confirm(playing: session.state == .playing) }
    }

    private var subtitle: String {
        let artist = [session.artist, session.album].compactMap { $0 }.first { !$0.isEmpty } ?? "Unknown artist"
        return "\(artist) · \(session.sourceName)"
    }

    private func run(_ action: ControlFeedback.Action, _ command: MediaCommand, step: Int = 0) {
        guard feedback.begin(action) else { return }
        if step != 0 { self.step = step }
        perform(command, action: action, on: session, media: media, feedback: $feedback)
    }
}

/// Sends a command to the session the user saw, then reports success or failure to `feedback`.
@MainActor
private func perform(_ command: MediaCommand, action: ControlFeedback.Action, on session: MediaSessionSnapshot,
                     media: MediaCoordinator, feedback: Binding<ControlFeedback>) {
    Task {
        var message: String?
        do throws(MediaError) {
            try await media.send(command, to: session.sourceID)
        } catch {
            message = ControlFeedback.message(for: error, source: session.sourceName)
        }
        feedback.wrappedValue.finish(action, error: message)
        if message == nil, action == .playPause {
            // Never hold a guess for long: if the source hasn't confirmed by now, show what it says.
            try? await Task.sleep(for: ControlFeedback.expectationLifetime)
            feedback.wrappedValue.expire()
        } else if message != nil {
            try? await Task.sleep(for: ControlFeedback.failureLifetime)
            feedback.wrappedValue.clearFailure()
        }
    }
}

/// Play/pause that flips at once, then follows the source; ignores clicks while one is in flight.
private struct PlayPauseButton: View {
    let session: MediaSessionSnapshot
    let media: MediaCoordinator
    @Binding var feedback: ControlFeedback
    let diameter: CGFloat
    /// An accent disc with a dark glyph; otherwise a white glyph alone (the full Music panel).
    var filled = true

    var body: some View {
        let playing = feedback.isPlaying(actual: session.state == .playing)
        Button {
            guard feedback.begin(.playPause, expectingPlaying: !playing) else { return }
            perform(.togglePlayPause, action: .playPause, on: session, media: media, feedback: $feedback)
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * (filled ? 0.44 : 0.52), weight: .bold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: diameter, height: diameter)
                .background(filled ? accent(.action) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .keyboardFocusRing(true, radius: diameter / 2) // ⏎ plays or pauses
        .disabled(!session.capabilities.contains(.playPause))
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

private struct ProgressRow: View {
    let session: MediaSessionSnapshot
    /// nil when the source can't seek; the bar is then display-only.
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// 0...1 while the user drags, and until the source confirms the new position.
    @State private var scrub: Double?

    /// Two ticks a second, and only while this row is on screen and playing. A per-frame
    /// progress view costs about a third of a CPU core on macOS.
    private static let tick: TimeInterval = 0.5

    var body: some View {
        // Without a known position (Music before permission) a bar would be a guess, so show none.
        if let duration = session.duration, duration > 0, let position = session.position {
            TimelineView(.periodic(from: session.positionDate, by: Self.tick)) { context in
                let now = session.state == .playing ? current(position, at: context.date) : position
                let shown = scrub.map { $0 * duration } ?? min(now, duration)
                row(shown: shown, duration: duration)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .onChange(of: session.positionDate) { scrub = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(clock(current(position, at: Date()))) of \(clock(duration))")
            .accessibilityAdjustableAction { direction in
                guard let onSeek else { return }
                let step: TimeInterval = direction == .increment ? 10 : -10
                onSeek(min(max(current(position, at: Date()) + step, 0), duration))
            }
        } else {
            // Live streams and some web players have no duration; keep the layout steady.
            Color.clear.frame(height: 18)
        }
    }

    /// The design's row: elapsed, a 5 pt white bar on a 16% track, time left.
    private func row(shown: TimeInterval, duration: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Text(clock(shown))
            Capsule()
                .fill(.white.opacity(0.16))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(.white).frame(width: geometry.size.width * min(max(shown / duration, 0), 1))
                    }
                }
                .overlay {
                    if let onSeek {
                        GeometryReader { geometry in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { scrub = fraction($0.location.x, geometry.size.width) }
                                    .onEnded {
                                        let target = fraction($0.location.x, geometry.size.width)
                                        scrub = target
                                        onSeek(target * duration)
                                        Task { // fall back if the source never confirms
                                            try? await Task.sleep(for: .seconds(1.5))
                                            scrub = nil
                                        }
                                    })
                        }
                        .frame(height: 14) // a comfortable hit area around the 5 pt bar
                    }
                }
            Text("-" + clock(max(duration - shown, 0)))
        }
    }

    private func current(_ position: TimeInterval, at date: Date) -> TimeInterval {
        session.state == .playing ? position + date.timeIntervalSince(session.positionDate) : position
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        width > 0 ? min(max(Double(x / width), 0), 1) : 0
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Which app or site is playing. Becomes a picker when more than one session exists.
private struct SourceBadge: View {
    let session: MediaSessionSnapshot
    let media: MediaCoordinator

    var body: some View {
        let canFocus = session.capabilities.contains(.focus)
        let label = HStack(spacing: 4) {
            Image(systemName: session.kind == .video ? "play.rectangle"
                  : session.providerID == BrowserMediaProvider.providerID ? "globe" : "speaker.wave.2.fill")
            Text(session.sourceName)
            if media.sessions.count > 1 { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.white.opacity(0.1), in: Capsule())

        if media.sessions.count > 1 {
            Menu {
                Button { media.select(nil) } label: {
                    if media.manualSourceID == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
                }
                Divider()
                ForEach(media.sessions) { other in
                    // Two tabs share a source name, so the track tells them apart.
                    let name = "\(other.sourceName) — \(other.title)"
                    Button { media.select(other.sourceID) } label: {
                        if media.manualSourceID == other.sourceID {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                if canFocus {
                    Divider()
                    Button("Show \(session.sourceName)") { focus() }
                }
            } label: { label }
            // The button style draws our label as-is; `.borderlessButton` re-renders it and drops the chevron.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Source: \(session.sourceName)")
        } else if canFocus {
            Button(action: focus) { label }
                .buttonStyle(PressableStyle())
                .help("Show \(session.sourceName)")
                .accessibilityLabel("Source: \(session.sourceName). Show it")
        } else {
            label.accessibilityLabel("Source: \(session.sourceName)")
        }
    }

    private func focus() {
        Task { try? await media.send(.focus, to: session.sourceID) }
    }
}

private struct PermissionLink: View {
    let text: String

    var body: some View {
        Button(text) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(accent(.action))
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var glyph: CGFloat = 13
    var frame: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(glyph > 13 ? 1 : 0.85))
                .frame(width: frame, height: frame) // consistent hit area regardless of glyph width
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Quick press-down feedback; releases with a small spring. Disabled controls are dimmed.
struct PressableStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
}

struct TabButtonStyle: ButtonStyle {
    let selected: Bool
    let namespace: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? .white : .white.opacity(0.55))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background {
                if selected {
                    // One indicator that slides between tabs.
                    Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "tab", in: namespace)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The collapsed island's two ears: leading left of the notch, trailing right of it.
private struct CollapsedEars: View {
    let layout: EarLayout
    let model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            part(layout.leading, .leading)
            Spacer(minLength: EarLayout.notchGap)
            part(layout.trailing, .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, EarLayout.padding)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func part(_ activity: LiveActivity?, _ side: EarSide) -> some View {
        switch activity?.payload {
        case .meeting(let event)?:
            // Minute steps are enough for "in N min"; the start itself is a calendar refresh boundary.
            // The schedule's date is the minute's start, so the countdown reads the clock itself.
            TimelineView(.everyMinute) { context in MeetingEarView(event: event, side: side, now: max(context.date, Date()), model: model) }
        case .focus(let kind)?:
            if side == .leading {
                FocusEar(module: model.focus, kind: kind)
            } else if kind == .onBreak {
                Text("break").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
        case .transient(let transient)?:
            TransientEar(transient: transient, side: side)
        case .nowPlaying(let session)?:
            MusicEar(session: session, side: side)
        case nil:
            EmptyView()
        }
    }
}

private struct MeetingEarView: View {
    let event: CalendarEvent
    let side: EarSide
    let now: Date
    let model: IslandModel

    var body: some View {
        if side == .leading {
            HStack(spacing: 7) {
                Circle().fill(event.color.color).frame(width: 7, height: 7)
                Text(MeetingEar.title(event, now: now)).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(event.title), \(CalendarDay.countdown(to: event.start, from: now))")
        } else if MeetingEar.showsJoin(event, now: now) {
            Button { model.join(event) } label: {
                Text("Join")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color(red: 0, green: 0.078, blue: 0.051)) // #00140D
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(accent(.action), in: Capsule())
                    .themeGlow(.action, radius: 7, opacity: 0.5)
            }
            .buttonStyle(PressableStyle())
            .padding(.trailing, -8) // the design's 6 pt right inset for the pill
            .accessibilityLabel("Join \(event.title)")
        } else {
            Text(CalendarDay.countdown(to: event.start, from: now))
                .foregroundStyle(accent(.live))
                .themeGlow(.live, radius: 5, opacity: 0.55)
                .accessibilityHidden(true)
        }
    }
}

/// A small ring and the time; redrawn once a second, and only while the session runs.
private struct FocusEar: View {
    let module: FocusModule
    let kind: FocusEarKind
    /// The M5 Moments design's break blue.
    static let breakBlue = Color(red: 0x8D / 255, green: 0xBB / 255, blue: 1)

    var body: some View {
        switch kind {
        case .running: running
        case .onBreak: onBreak
        case .done(let label):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                Text(label)
            }
            .foregroundStyle(accent(.live))
            .accessibilityElement(children: .combine)
        }
    }

    private var onBreak: some View {
        TimelineView(.animation(minimumInterval: 1)) { context in
            let remaining = module.breakRemaining(at: context.date)
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 11))
                Text(FocusSession.text(remaining)).monospacedDigit()
            }
            .foregroundStyle(Self.breakBlue)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Break, \(FocusSession.text(remaining)) left")
        }
    }

    private var running: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !module.isRunning)) { context in
            let now = module.isRunning ? context.date : module.now()
            let remaining = module.remaining(at: now)
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2.4)
                    Circle()
                        .trim(from: 0, to: module.fraction(at: now))
                        .stroke(accent(.live), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text(FocusSession.text(remaining)).monospacedDigit()
            }
            .foregroundStyle(accent(.live).opacity(module.isRunning ? 1 : 0.55))
            .themeGlow(.live, radius: 5, opacity: module.isRunning ? 0.5 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Focus timer \(FocusSession.text(remaining))\(module.isRunning ? "" : ", paused")")
        }
    }
}

private struct TransientEar: View {
    let transient: Transient
    let side: EarSide

    var body: some View {
        if side == .leading {
            HStack(spacing: 7) {
                Image(systemName: transient.symbol).font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(transient.warning ? SettingsDesign.amber : accent(.rest))
                Text(transient.title).lineLimit(1)
                    .foregroundStyle(transient.warning ? SettingsDesign.amber : .white)
            }
            .accessibilityElement(children: .combine)
        } else if let pill = transient.pill {
            // The M5 System design's "Restart": 22 pt, 14% white.
            Text(pill)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(.white.opacity(0.14), in: Capsule())
        } else if let detail = transient.detail {
            Text(detail)
                .font(.system(size: 12, design: transient.monospaced ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 96, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The cover on the left, four warm bars on the right (the design's #F7B56E).
private struct MusicEar: View {
    let session: MediaSessionSnapshot
    let side: EarSide
    static let barColor = NSColor(red: 0.969, green: 0.71, blue: 0.431, alpha: 1)
    static let warm = Color(nsColor: barColor) // #F7B56E

    var body: some View {
        if side == .leading {
            Artwork(seed: session.title, url: session.artworkURL, size: 20, radius: 6)
                .accessibilityLabel("Now playing: \(session.title)")
        } else if session.kind == .video {
            ActivityIndicator(session: session)
        } else {
            EqualizerView(mode: EqualizerView.Mode(session), color: Self.barColor, style: .wave)
        }
    }
}
