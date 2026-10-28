import AppKit
import SwiftUI

/// Orilio's accent: a neon green that stays readable as text and controls on the black island.
let mint = Color(red: 0.169, green: 1.0, blue: 0.722) // #2BFFB8, the M3 hub design's accent
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
struct IslandShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { (ear, bottom) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let geometry = model.geometry
        let state = model.state
        let open = state.isOpen
        let size = geometry.size(for: state, tall: model.showsTallPanel, collapsedWidth: model.liveCollapsedWidth)
        let ear = open ? IslandGeometry.earRadius : 0
        let radius = switch state {
        case .collapsed: Metrics.collapsedRadius
        case .expanded, .dropTarget: Metrics.previewRadius
        case .pinned: Metrics.openRadius
        }
        let shape = IslandShape(ear: ear, bottom: radius)

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                // The design's 0 24 60 rgba(0,0,0,.55), kept inside the window's shadow margin.
                .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 18, y: 14)

            ZStack(alignment: .top) {
                switch state {
                case .pinned:
                    // The header shares the notch's row, so content starts at the very top.
                    ExpandedContent(model: model)
                        .padding(.horizontal, ear)
                        .transition(contentTransition)
                case .expanded:
                    PreviewContent(media: model.media)
                        .padding(.top, geometry.topInset)
                        .padding(.horizontal, ear)
                        .transition(contentTransition)
                case .dropTarget:
                    DropTargetView(valid: model.dropIsValid, destination: model.dropGoesToScreenshots ? "Screenshots" : "Shelf")
                        .padding(.top, geometry.topInset)
                        .padding(.horizontal, ear)
                        .transition(contentTransition)
                case .collapsed:
                    if let meeting = model.meetingSoon {
                        TimelineView(.everyMinute) { context in MeetingPill(event: meeting, now: context.date) }
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    } else if !geometry.hasNotch {
                        CompactPill(media: model.media)
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    }
                }
            }
            .clipShape(shape)
        }
        .frame(width: size.width + 2 * ear, height: size.height)
        .contentShape(shape)
        // Clicking the pill or the preview (outside its buttons) opens the full controller.
        .onTapGesture { if state != .pinned { model.tap() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orilio island")
        .accessibilityAction(named: "Open controls") { model.tap() }
        .animation(shapeAnimation(collapsing: state == .collapsed), value: state)
        // The Screenshots grid makes the open panel taller without a state change: grow and shrink
        // the same way (the window keeps its larger size until the shrink has finished).
        .animation(shapeAnimation(collapsing: !model.showsTallPanel), value: model.showsTallPanel)
        // Outside the animation on purpose: the window resizes instantly and the island must stay
        // pinned to the top edge, not glide from its old position.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .reveal(reduceMotion).animation(
                reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0).delay(0.08)),
            // Leaving content gets out of the way before the shape changes under it.
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private func shapeAnimation(collapsing: Bool) -> Animation? {
        if reduceMotion { return nil }
        // Springs are interruptible: hovering back mid-close retargets from where the shape is.
        return collapsing
            ? .spring(duration: IslandModel.closeDuration, bounce: 0)
            : .spring(duration: IslandModel.openDuration, bounce: 0.22)
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
                .foregroundStyle(mint.opacity(playing ? 1 : 0.5))
                .accessibilityHidden(true)
        } else {
            EqualizerView(mode: EqualizerView.Mode(session, expectedPlaying: expectedPlaying), color: NSColor(mint))
        }
    }
}

/// The hover state: enough to see what's playing and pause it, without opening the full panel.
private struct PreviewContent: View {
    let media: MediaCoordinator
    @State private var feedback = ControlFeedback()

    var body: some View {
        HStack(spacing: Metrics.previewPadding) {
            if let session = media.current {
                Artwork(seed: session.title, url: session.artworkURL, size: 40, radius: Metrics.previewInnerRadius)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(session.artist ?? session.sourceName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(Metrics.secondaryText))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                ActivityIndicator(session: session, expectedPlaying: feedback.expectedPlaying)
                PlayPauseButton(session: session, media: media, feedback: $feedback, diameter: 28)
            } else {
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(Metrics.secondaryText))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Metrics.previewPadding + 4)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: media.current?.title)
    }
}

private struct ExpandedContent: View {
    @Bindable var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // 38 pt header: tabs left of the notch, pin and close right of it (M3 hub design).
            HStack(spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(IslandTab.allCases) { tab in
                        ModuleTab(tab: tab, selected: model.tab == tab, live: isLive(tab)) { model.tab = tab }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Modules")
                Spacer()
                HeaderButton(symbol: model.state == .pinned ? "pin.fill" : "pin", label: "Keep island open",
                             active: model.state == .pinned) { model.togglePin() }
                HeaderButton(symbol: "xmark", label: "Close island (Esc)", active: false) { model.dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(height: max(IslandGeometry.headerHeight, model.geometry.topInset))

            ZStack {
                switch model.tab {
                case .calendar: CalendarPanel(module: model.calendar)
                case .clipboard: ClipboardPanel(module: model.clipboard, library: model.library)
                case .notes: NotesPanel(module: model.notes)
                case .music: MusicCard(media: model.media)
                case .shelf: ShelfView(shelf: model.shelf, library: model.library, section: $model.shelfSection,
                                       draggedOut: { model.dismiss() })
                }
            }
            .id(model.tab)
            .transition(.reveal(reduceMotion))
            .padding(.top, 10)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: model.tab)
    }

    /// A small dot on a tab that has something live while another tab is shown.
    private func isLive(_ tab: IslandTab) -> Bool {
        guard model.tab != tab else { return false }
        switch tab {
        case .calendar: return model.meetingSoon != nil
        case .music: return model.media.current?.state == .playing
        case .clipboard, .notes, .shelf: return false
        }
    }
}

/// A 32 × 28 icon tab (radius 9): white on a 14% plate when selected, 55% white otherwise.
private struct ModuleTab: View {
    let tab: IslandTab
    let selected: Bool
    let live: Bool
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
                        Circle().fill(mint).frame(width: 5, height: 5)
                            .shadow(color: mint, radius: 3)
                            .padding(.top, 4).padding(.trailing, 5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(tab.rawValue)
        .accessibilityLabel(tab.rawValue)
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
                .foregroundStyle(active ? mint : .white.opacity(0.6))
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
    let media: MediaCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let session = media.current {
                NowPlaying(session: session, media: media)
                    // A different source is a different card: cross-fade, and start with fresh control state.
                    .id(session.sourceID)
                    .transition(.opacity)
            } else {
                EmptyMusicState(media: media)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: media.current?.sourceID)
    }
}

private struct NowPlaying: View {
    let session: MediaSessionSnapshot
    let media: MediaCoordinator
    /// Direction of the last skip the user asked for, for the title transition.
    @State private var step = 1
    @State private var feedback = ControlFeedback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caps = session.capabilities
        let denied = media.statuses[session.providerID] == .permissionDenied
        HStack(spacing: Metrics.padding) {
            Artwork(seed: session.title, url: session.artworkURL, size: 96, radius: Metrics.innerRadius)
                .overlay {
                    if session.artworkURL == nil {
                        Image(systemName: "music.note").font(.system(size: 32)).foregroundStyle(.black.opacity(0.4))
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.title.isEmpty ? "Unknown title" : session.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ActivityIndicator(session: session, expectedPlaying: feedback.expectedPlaying)
                    }
                    if let failure = feedback.failure {
                        Label(failure, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    } else {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(Metrics.secondaryText))
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(session.title)
                // Next slides in from the right, previous from the left.
                .transition(reduceMotion ? .opacity : .push(from: step > 0 ? .trailing : .leading))
                .clipped()

                ProgressRow(session: session,
                            onSeek: caps.contains(.seek) ? { run(.seek, .seek(to: $0)) } : nil)
                    .padding(.top, 10)

                HStack(spacing: 22) {
                    if denied && !caps.contains(.playPause) {
                        PermissionLink(text: "Allow control of \(session.sourceName)")
                    } else {
                        // Unsupported controls stay in place, dimmed, so the layout doesn't jump between sources.
                        IconButton(symbol: "backward.fill", label: "Previous track") { run(.skip, .previous, step: -1) }
                            .disabled(!caps.contains(.previous) || feedback.inFlight.contains(.skip))
                            .keyboardShortcut(.leftArrow, modifiers: .command)
                        PlayPauseButton(session: session, media: media, feedback: $feedback, diameter: 34)
                            .keyboardShortcut(.space, modifiers: [])
                        IconButton(symbol: "forward.fill", label: "Next track") { run(.skip, .next, step: 1) }
                            .disabled(!caps.contains(.next) || feedback.inFlight.contains(.skip))
                            .keyboardShortcut(.rightArrow, modifiers: .command)
                    }
                    Spacer(minLength: 0)
                    SourceBadge(session: session, media: media)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Animate what the user can see change, not every heartbeat that refreshes the snapshot.
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1), value: session.title)
        .animation(.easeInOut(duration: 0.2), value: feedback.failure)
        .onChange(of: session.state) { feedback.confirm(playing: session.state == .playing) }
    }

    private var subtitle: String {
        let parts = [session.artist, session.album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown artist" : parts.joined(separator: " — ")
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

    var body: some View {
        let playing = feedback.isPlaying(actual: session.state == .playing)
        Button {
            guard feedback.begin(.playPause, expectingPlaying: !playing) else { return }
            perform(.togglePlayPause, action: .playPause, on: session, media: media, feedback: $feedback)
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.44, weight: .bold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(.black)
                .frame(width: diameter, height: diameter)
                .background(mint, in: Circle())
        }
        .buttonStyle(PressableStyle())
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
            .tint(mint)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(Metrics.secondaryText))
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

    private func row(shown: TimeInterval, duration: TimeInterval) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: shown, total: duration)
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
                        .frame(height: 14) // a comfortable hit area around the 4pt bar
                    }
                }
            HStack {
                Text(clock(shown))
                Spacer()
                Text(clock(duration))
            }
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
        let isDemo = session.providerID == DemoMediaProvider.providerID
        let canFocus = session.capabilities.contains(.focus)
        let label = HStack(spacing: 4) {
            Image(systemName: isDemo ? "testtube.2" : session.kind == .video ? "play.rectangle"
                  : session.providerID == BrowserMediaProvider.providerID ? "globe" : "speaker.wave.2.fill")
            Text(session.sourceName)
            if media.sessions.count > 1 { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isDemo ? .black : .white.opacity(0.75))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isDemo ? mint.opacity(0.85) : .white.opacity(0.1), in: Capsule())

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
            label.accessibilityLabel("Source: \(session.sourceName)\(isDemo ? ", not real playback" : "")")
        }
    }

    private func focus() {
        Task { try? await media.send(.focus, to: session.sourceID) }
    }
}

private struct EmptyMusicState: View {
    let media: MediaCoordinator

    var body: some View {
        let denied = media.statuses.filter { $0.value == .permissionDenied }.keys.map(media.providerName).sorted()
        HStack(spacing: Metrics.padding) {
            RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                .fill(.white.opacity(0.06))
                .frame(width: 96, height: 96)
                .overlay(Image(systemName: denied.isEmpty ? "music.note" : "lock.fill")
                    .font(.system(size: 28)).foregroundStyle(.white.opacity(0.3)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if denied.isEmpty {
                    Text("Nothing playing").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("Start music in a supported app and it appears here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text("Permission needed").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("Allow Orilio to control \(denied.formatted()) in Privacy & Security › Automation.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    PermissionLink(text: "Open System Settings").padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
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
        .foregroundStyle(mint)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 26) // consistent hit area regardless of glyph width
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
