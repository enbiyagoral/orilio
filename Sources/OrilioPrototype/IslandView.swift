import AppKit
import SwiftUI

private let mint = Color(red: 0.63, green: 0.95, blue: 0.84)
private let coverGradient = LinearGradient(
    colors: [Color(red: 0.96, green: 0.78, blue: 0.68), Color(red: 0.96, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.27, blue: 0.56)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

// Radii are concentric: outer = inner + padding (14 + 18 = 32).
private enum Metrics {
    static let padding: CGFloat = 18
    static let innerRadius: CGFloat = 14
    static let openRadius: CGFloat = padding + innerRadius
    static let collapsedRadius: CGFloat = 10
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
        let open = model.state.isOpen
        let size = open ? geometry.expanded : geometry.collapsed
        let ear = open ? IslandGeometry.earRadius : 0
        let shape = IslandShape(ear: ear, bottom: open ? Metrics.openRadius : Metrics.collapsedRadius)

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, y: 8)

            ZStack(alignment: .top) {
                if open {
                    ExpandedContent(model: model)
                        .padding(.top, geometry.topInset)
                        .padding(.horizontal, ear)
                        .transition(.asymmetric(
                            insertion: .reveal(reduceMotion).animation(
                                reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0).delay(0.08)),
                            // Leaving content gets out of the way before the shape closes over it.
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else if !geometry.hasNotch {
                    CompactPill(media: model.media)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
            .clipShape(shape)
        }
        .frame(width: size.width + 2 * ear, height: size.height)
        .contentShape(shape)
        .onTapGesture { if !open { model.tapCollapsed() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orilio island")
        .animation(shapeAnimation(opening: open), value: model.state)
        // Outside the animation on purpose: the window resizes instantly and the island must stay
        // pinned to the top edge, not glide from its old position.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func shapeAnimation(opening: Bool) -> Animation? {
        if reduceMotion { return nil }
        return opening
            ? .spring(duration: IslandModel.openDuration, bounce: 0.22)
            : .spring(duration: IslandModel.closeDuration, bounce: 0)
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
                // Static on purpose: an animated waveform would keep the GPU busy while idle.
                Image(systemName: session.state == .playing ? "waveform" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(mint)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

private struct ExpandedContent: View {
    @Bindable var model: IslandModel
    @Namespace private var tabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("ORILIO")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(IslandTab.allCases) { tab in
                        Button(tab.rawValue) {
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) { model.tab = tab }
                        }
                        .buttonStyle(TabButtonStyle(selected: model.tab == tab, namespace: tabs))
                    }
                }
                .padding(3)
                .background(.white.opacity(0.07), in: Capsule())
                Spacer()
                IconButton(symbol: model.state == .pinned ? "pin.fill" : "pin",
                           label: model.state == .pinned ? "Unpin" : "Keep open") { model.togglePin() }
                IconButton(symbol: "xmark", label: "Close") { model.dismiss() }
            }

            ZStack {
                switch model.tab {
                case .music: MusicCard(media: model.media)
                case .shelf: ShelfPlaceholder()
                }
            }
            .id(model.tab)
            .transition(.reveal(reduceMotion))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, 6)
        .padding(.bottom, Metrics.padding)
    }
}

/// Real cover art when the source has it, loaded off the main path; otherwise a gradient tinted per title.
private struct Artwork: View {
    let seed: String
    var url: URL? = nil
    let size: CGFloat
    let radius: CGFloat
    @State private var image: NSImage?

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(coverGradient).hueRotation(.degrees(hue))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: url) {
            guard let url else { image = nil; return }
            let data = await ArtworkCache.shared.data(for: url)
            // Decoded on the main actor; covers are a few hundred KB at most.
            withAnimation(.easeOut(duration: 0.2)) { image = data.flatMap(NSImage.init(data:)) }
        }
    }
}

private struct MusicCard: View {
    let media: MediaCoordinator

    var body: some View {
        if let session = media.current {
            NowPlaying(session: session, media: media)
        } else {
            EmptyMusicState(media: media)
        }
    }
}

private struct NowPlaying: View {
    let session: MediaSessionSnapshot
    let media: MediaCoordinator
    /// Direction of the last skip the user asked for, for the title transition.
    @State private var step = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caps = session.capabilities
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
                    Text(session.title.isEmpty ? "Unknown title" : session.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(session.sourceID + session.title)
                // Next slides in from the right, previous from the left.
                .transition(reduceMotion ? .opacity : .push(from: step > 0 ? .trailing : .leading))
                .clipped()

                ProgressRow(session: session,
                            onSeek: caps.contains(.seek) ? { send(.seek(to: $0)) } : nil)
                    .padding(.top, 10)

                HStack(spacing: 22) {
                    // Only what this source can actually do; nothing is shown just to look complete.
                    if caps.contains(.previous) {
                        IconButton(symbol: "backward.fill", label: "Previous track") { send(.previous, step: -1) }
                    }
                    if caps.contains(.playPause) {
                        Button { send(.togglePlayPause) } label: {
                            Image(systemName: session.state == .playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .contentTransition(.symbolEffect(.replace.downUp))
                                .foregroundStyle(.black)
                                .frame(width: 34, height: 34)
                                .background(mint, in: Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel(session.state == .playing ? "Pause" : "Play")
                    }
                    if caps.contains(.next) {
                        IconButton(symbol: "forward.fill", label: "Next track") { send(.next, step: 1) }
                    }
                    if caps.isEmpty, media.statuses[session.providerID] == .permissionDenied {
                        PermissionLink(text: "Allow control of \(session.sourceName)")
                    }
                    Spacer(minLength: 0)
                    SourceBadge(session: session, media: media)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1), value: session)
    }

    private var subtitle: String {
        let parts = [session.artist, session.album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown artist" : parts.joined(separator: " — ")
    }

    private func send(_ command: MediaCommand, step: Int = 0) {
        if step != 0 { self.step = step }
        // The target is the session on screen, not whatever is current when the call lands.
        Task { try? await media.send(command, to: session.sourceID) }
    }
}

private struct ProgressRow: View {
    let session: MediaSessionSnapshot
    /// nil when the source can't seek; the bar is then display-only.
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// 0...1 while the user drags, and until the source confirms the new position.
    @State private var scrub: Double?

    var body: some View {
        // Without a known position (Music before permission) a bar would be a guess, so show none.
        if let duration = session.duration, duration > 0, let rawPosition = session.position {
            let position = min(rawPosition, duration)
            // The system advances these itself; no timer of ours runs while music plays.
            let start = session.positionDate.addingTimeInterval(-position)
            let range = start...start.addingTimeInterval(duration)
            VStack(spacing: 4) {
                Group {
                    if let scrub {
                        ProgressView(value: scrub)
                    } else if session.state == .playing {
                        ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    } else {
                        ProgressView(value: position, total: duration)
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
                        .frame(height: 14) // a comfortable hit area around the 4pt bar
                    }
                }
                HStack {
                    if let scrub {
                        Text(clock(scrub * duration))
                    } else if session.state == .playing {
                        Text(timerInterval: range, countsDown: false)
                    } else {
                        Text(clock(position))
                    }
                    Spacer()
                    Text(clock(duration))
                }
            }
            .tint(mint)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .onChange(of: session.positionDate) { scrub = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(clock(current(position))) of \(clock(duration))")
            .accessibilityAdjustableAction { direction in
                guard let onSeek else { return }
                let step: TimeInterval = direction == .increment ? 10 : -10
                onSeek(min(max(current(position) + step, 0), duration))
            }
        } else {
            // Live streams and some web players have no duration; keep the layout steady.
            Color.clear.frame(height: 18)
        }
    }

    private func current(_ position: TimeInterval) -> TimeInterval {
        session.state == .playing ? position + Date().timeIntervalSince(session.positionDate) : position
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        width > 0 ? min(max(Double(x / width), 0), 1) : 0
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
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
            Image(systemName: isDemo ? "testtube.2" : session.providerID == BrowserMediaProvider.providerID ? "globe" : "speaker.wave.2.fill")
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
            .menuStyle(.borderlessButton)
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

private struct ShelfPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
            .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 20))
                    Text("Shelf arrives in M1").font(.system(size: 13, weight: .semibold))
                    Text("Drag and drop isn't wired up in this prototype.").font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .frame(height: 96)
    }
}

private struct IconButton: View {
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

/// Quick press-down feedback; releases with a small spring.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

private struct TabButtonStyle: ButtonStyle {
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
