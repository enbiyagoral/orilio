import AppKit
import SwiftUI

/// Playback activity, not audio amplitude: five bars that move while playing, settle when paused,
/// and breathe while loading. Drawn with Core Animation, so the motion runs in the render server
/// without waking Orilio every frame.
struct EqualizerView: NSViewRepresentable {
    enum Mode: Equatable {
        case playing, paused, buffering
    }

    let mode: Mode
    var color: NSColor = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView() }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.apply(mode, color: color, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerLayerView, context: Context) -> CGSize? {
        EqualizerLayerView.size
    }
}

final class EqualizerLayerView: NSView {
    static let size = CGSize(width: 16, height: 14)
    private static let barWidth: CGFloat = 2
    /// Each bar moves inside its own envelope, tallest in the middle and lower toward the edges,
    /// so the group always reads as one arch instead of a row of spikes.
    private static let low: [CGFloat] = [0.15, 0.25, 0.35, 0.25, 0.15]
    private static let high: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    /// Heights at rest (paused): the same arch, settled.
    private static let rest: [CGFloat] = [0.3, 0.5, 0.7, 0.5, 0.3]
    /// Different periods so the bars never line up into an obvious loop.
    private static let periods: [CFTimeInterval] = [0.43, 0.57, 0.37, 0.61, 0.49]

    private var bars: [CALayer] = []
    private var current: EqualizerView.Mode?
    private var currentReduceMotion = false

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        for _ in Self.rest {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5) // grow both ways from the middle
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(false) // the state is spoken by the controls next to it
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { Self.size }

    override func layout() {
        super.layout()
        let gap = (bounds.width - Self.barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + gap) + Self.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    func apply(_ mode: EqualizerView.Mode, color: NSColor, reduceMotion: Bool) {
        bars.forEach { $0.backgroundColor = color.cgColor }
        guard mode != current || reduceMotion != currentReduceMotion else { return }
        current = mode
        currentReduceMotion = reduceMotion

        bars.forEach { $0.removeAnimation(forKey: "level") }
        layer?.removeAnimation(forKey: "breathe")

        // Settle into the resting shape; this short ease is the only motion when paused.
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.3)
        for (index, bar) in bars.enumerated() {
            let scale = mode == .buffering ? 0.3 : Self.rest[index]
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        layer?.opacity = mode == .paused ? 0.45 : 1
        CATransaction.commit()

        guard !reduceMotion else { return }
        switch mode {
        case .playing:
            for (index, bar) in bars.enumerated() {
                let level = CABasicAnimation(keyPath: "transform.scale.y")
                level.fromValue = Self.low[index]
                level.toValue = Self.high[index]
                level.duration = Self.periods[index]
                level.autoreverses = true
                level.repeatCount = .infinity
                level.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                level.beginTime = CACurrentMediaTime() - Double(index) * 0.13 // start out of phase
                bar.add(level, forKey: "level")
            }
        case .buffering:
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.35
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            layer?.add(breathe, forKey: "breathe")
        case .paused:
            break
        }
    }
}

extension EqualizerView.Mode {
    init(_ session: MediaSessionSnapshot, expectedPlaying: Bool? = nil) {
        let playing = expectedPlaying ?? (session.state == .playing)
        self = !playing ? .paused : session.isBuffering ? .buffering : .playing
    }
}
