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
        /// The collapsed music state: five 2 pt bars with 2 pt gaps, so it reads as one wave rather than
        /// a row of blocks. The peaks don't line up in the middle, and the slow, uneven periods keep it
        /// from looking like a loop.
        static let wave = Style(size: CGSize(width: 18, height: 16), barWidth: 2,
                                low: [0.2, 0.35, 0.25, 0.4, 0.2], high: [0.5, 0.9, 0.65, 1.0, 0.55],
                                rest: [0.3, 0.55, 0.4, 0.6, 0.35], periods: [0.9, 1.07, 1.24, 0.97, 1.33], phase: 0.12)
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
    /// Each bar's resting height as a fraction of the view's.
    private var levels: [CGFloat]
    private var current: EqualizerView.Mode?
    private var currentReduceMotion = false

    init(style: EqualizerView.Style = .arch) {
        self.style = style
        levels = style.rest
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
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: height(levels[index]))
            bar.position = CGPoint(x: CGFloat(index) * (style.barWidth + gap) + style.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    /// Bars change height, never scale: a scaled bar squashes its round caps.
    /// Never shorter than a dot, so a bar doesn't vanish.
    private func height(_ level: CGFloat) -> CGFloat { max(style.barWidth, level * style.size.height) } // fixed size; set before layout too

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
        levels = style.rest.map { mode == .buffering ? 0.3 : $0 }
        for (index, bar) in bars.enumerated() {
            bar.bounds.size.height = height(levels[index])
        }
        layer?.opacity = mode == .paused ? 0.45 : 1
        CATransaction.commit()

        guard !reduceMotion else { return }
        switch mode {
        case .playing:
            for (index, bar) in bars.enumerated() {
                let level = CABasicAnimation(keyPath: "bounds.size.height")
                level.fromValue = height(style.low[index])
                level.toValue = height(style.high[index])
                level.duration = style.periods[index]
                level.autoreverses = true
                level.repeatCount = .infinity
                level.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                level.beginTime = CACurrentMediaTime() - Double(index) * style.phase // start out of phase
                // Slow, small bars look the same at 30 fps; without this the window server redraws them
                // at the display's full rate (120 Hz on ProMotion) for as long as music plays.
                level.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
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
