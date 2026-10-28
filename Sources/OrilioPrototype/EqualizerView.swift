// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

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
    var style: Style = .arch
    @Environment(\.reducesMotion) private var reduceMotion

    /// The bars' shape and motion.
    struct Style: Equatable {
        var size: CGSize
        var barWidth: CGFloat
        /// Each bar moves inside its own envelope (fractions of the height).
        var low: [CGFloat]
        var high: [CGFloat]
        /// Heights at rest (paused).
        var rest: [CGFloat]
        /// Different periods so the bars never line up into an obvious loop.
        var periods: [CFTimeInterval]
        var phase: CFTimeInterval

        /// Five bars, tallest in the middle and lower toward the edges, so the group reads as one
        /// arch instead of a row of spikes (the M1 player).
        static let arch = Style(size: CGSize(width: 16, height: 14), barWidth: 2,
                                low: [0.15, 0.25, 0.35, 0.25, 0.15], high: [0.45, 0.75, 1.0, 0.75, 0.45],
                                rest: [0.3, 0.5, 0.7, 0.5, 0.3], periods: [0.43, 0.57, 0.37, 0.61, 0.49], phase: 0.13)
        /// The M3 hub design's collapsed music state: four 3 pt bars, 6/12/8/14 of 16 pt, slow waves.
        static let wave = Style(size: CGSize(width: 19.5, height: 16), barWidth: 3,
                                low: [0.15, 0.3, 0.2, 0.35], high: [0.375, 0.75, 0.5, 0.875],
                                rest: [0.3, 0.55, 0.4, 0.6], periods: [0.9, 1.07, 1.24, 1.41], phase: 0.12)
    }

    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView(style: style) }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.apply(mode, color: color, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerLayerView, context: Context) -> CGSize? {
        style.size
    }
}

final class EqualizerLayerView: NSView {
    private let style: EqualizerView.Style
    private var bars: [CALayer] = []
    private var current: EqualizerView.Mode?
    private var currentReduceMotion = false

    init(style: EqualizerView.Style = .arch) {
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: style.size))
        wantsLayer = true
        for _ in style.rest {
            let bar = CALayer()
            bar.cornerRadius = style.barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5) // grow both ways from the middle
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(false) // the state is spoken by the controls next to it
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { style.size }

    override func layout() {
        super.layout()
        let gap = (bounds.width - style.barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (style.barWidth + gap) + style.barWidth / 2, y: bounds.midY)
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
            let scale = mode == .buffering ? 0.3 : style.rest[index]
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        layer?.opacity = mode == .paused ? 0.45 : 1
        CATransaction.commit()

        guard !reduceMotion else { return }
        switch mode {
        case .playing:
            for (index, bar) in bars.enumerated() {
                let level = CABasicAnimation(keyPath: "transform.scale.y")
                level.fromValue = style.low[index]
                level.toValue = style.high[index]
                level.duration = style.periods[index]
                level.autoreverses = true
                level.repeatCount = .infinity
                level.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                level.beginTime = CACurrentMediaTime() - Double(index) * style.phase // start out of phase
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
