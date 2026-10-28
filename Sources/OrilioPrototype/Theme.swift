// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI

/// Colors, glow and motion for the island, from the preferences. Views ask by role instead of
/// naming a color:
/// - `.live`: what is happening now (the focus ring, a countdown, live dots, playing bars);
/// - `.action`: what can be acted on now (Join, Start, the main button of a pane);
/// - `.rest`: everything else that is highlighted (selection, a checked task, a copied row).
struct Theme: Equatable {
    enum Role { case rest, action, live }

    let style: Preferences.ThemeStyle
    let accent: Color
    let motion: Preferences.Motion

    /// The system's Reduce Motion wins over the user's choice when "Follow system Reduce Motion" is on.
    static func resolve(_ preferences: Preferences, systemReduceMotion: Bool) -> Theme {
        Theme(style: preferences.theme, accent: preferences.accent.color,
              motion: preferences.followReduceMotion && systemReduceMotion ? .off : preferences.motion)
    }

    @MainActor static var current: Theme {
        resolve(PreferencesStore.shared.value, systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Calm: white everywhere. Neon: the accent everywhere. Adaptive: white at rest, the accent for
    /// live and actionable things.
    func color(_ role: Role) -> Color {
        switch (style, role) {
        case (.calm, _), (.adaptive, .rest): .white
        case (.neon, _), (.adaptive, _): accent
        }
    }

    /// 0 (no glow) or 1 (the full soft glow), multiplied into each element's own glow.
    func glow(_ role: Role) -> Double {
        switch (style, role) {
        case (.calm, _), (.adaptive, .rest): 0
        case (.neon, _), (.adaptive, _): 1
        }
    }

    var reducesMotion: Bool { motion == .off }

    /// Spring: as designed. Subtle: the same timing without overshoot. Off: no animation.
    func spring(duration: Double, bounce: Double = 0) -> Animation? {
        switch motion {
        case .spring: .spring(duration: duration, bounce: bounce)
        case .subtle: .spring(duration: duration * 0.85, bounce: 0)
        case .off: nil
        }
    }
}

/// The current theme's color for a role (reading it ties the view to the preferences).
@MainActor func accent(_ role: Theme.Role = .action) -> Color { Theme.current.color(role) }

extension View {
    /// The element's soft glow, scaled by the theme (none in Calm).
    @MainActor func themeGlow(_ role: Theme.Role, radius: CGFloat, opacity: Double = 0.5) -> some View {
        shadow(color: accent(role).opacity(opacity * Theme.current.glow(role)), radius: radius)
    }
}

extension EnvironmentValues {
    /// Settings › Appearance › Animation "Off", or the system's Reduce Motion when followed. Read it
    /// instead of `accessibilityReduceMotion`, which ignores the user's choice in Orilio.
    @Entry var reducesMotion = false
}
