// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import SwiftUI

/// One card for every permission request, empty state and error in the island (the M5
/// Permissions and States designs). It never animates: empty states are still.
struct StatusCard: View {
    enum Tone: Equatable {
        /// Nothing here yet: a 8% white tile, a 75% white icon.
        case empty
        /// All good: mint.
        case good
        /// Needs you: #FFB86B, with a mint primary button.
        case warn
        /// Asking for access the first time, in the module's own color (the permission cards).
        case ask(tile: Color, ink: Color)
    }

    enum Layout { case card, ask, banner }

    struct Action {
        let title: String
        let run: () -> Void
        init(_ title: String, _ run: @escaping () -> Void) {
            self.title = title
            self.run = run
        }
    }

    let tone: Tone
    let symbol: String
    let title: String
    let detail: String
    var primary: Action? = nil
    var secondary: Action? = nil
    var layout: Layout = .card

    private static let mint = SettingsDesign.mint
    private static let amber = SettingsDesign.amber
    private static let ink = SettingsDesign.hex(0x00140D)

    var body: some View {
        switch layout {
        case .card, .ask: vertical
        case .banner: banner
        }
    }

    // M5States: a 40 pt tile (radius 12), a 14.5 pt title and a 12 pt note, 30 pt buttons.
    // M5Permissions: a 48 pt tile (radius 14), a 16 pt title and a 12.5 pt note, 36 pt buttons.
    private var vertical: some View {
        let ask = layout == .ask
        return VStack(spacing: ask ? 12 : 8) {
            tile(size: ask ? 48 : 40, radius: ask ? 14 : 12, icon: ask ? 22 : 18)
            Text(title)
                .font(.system(size: ask ? 16 : 14.5, weight: .semibold))
                .tracking(ask ? -0.16 : -0.145)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(detail)
                .font(.system(size: ask ? 12.5 : 12))
                .lineSpacing(ask ? 12.5 * 0.45 - 2 : 12 * 0.4 - 2)
                .foregroundStyle(.white.opacity(ask ? 0.62 : 0.58))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: ask ? 360 : 320)
                .fixedSize(horizontal: false, vertical: true)
            if primary != nil || secondary != nil {
                HStack(spacing: ask ? 8 : 6) {
                    if let secondary { button(secondary, primary: false, ask: ask) }
                    if let primary { button(primary, primary: true, ask: ask) }
                }
                .padding(.top, ask ? 6 : 4)
            }
            if tone == .warn {
                // Something went wrong: one quiet way to tell about it (the M5 Feedback design).
                Button("Report this") { FeedbackWindow.show(kind: .bug, context: title) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // The M5 Permissions "denied" card: tile left, text, one button right.
    private var banner: some View {
        HStack(spacing: 16) {
            tile(size: 44, radius: 13, icon: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let secondary {
                bannerButton(secondary)
            }
            if let primary {
                bannerButton(primary)
            }
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 72)
        .accessibilityElement(children: .contain)
    }

    private var colors: (tile: Color, ink: Color) {
        switch tone {
        case .empty: (.white.opacity(0.08), .white.opacity(0.75))
        case .good: (Self.mint.opacity(0.12), Self.mint)
        case .warn: (Self.amber.opacity(0.14), Self.amber)
        case .ask(let tile, let ink): (tile, ink)
        }
    }

    private func tile(size: CGFloat, radius: CGFloat, icon: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: icon, weight: .regular))
            .foregroundStyle(colors.ink)
            .frame(width: size, height: size)
            .background(colors.tile, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Warn and ask cards put the next step in mint; the others keep a quiet 14% white.
    private var primaryIsMint: Bool {
        switch tone {
        case .warn, .ask: true
        case .empty, .good: false
        }
    }

    private func button(_ action: Action, primary: Bool, ask: Bool) -> some View {
        let mint = primary && primaryIsMint
        return Button(action: action.run) {
            Text(action.title)
                .font(.system(size: ask ? 13 : 12, weight: primary ? .semibold : .medium))
                .foregroundStyle(mint ? Self.ink : .white)
                .padding(.horizontal, ask ? (primary ? 16 : 14) : 12)
                .frame(height: ask ? 36 : 30)
                .background(mint ? Self.mint : .white.opacity(primary ? 0.14 : 0.1),
                            in: RoundedRectangle(cornerRadius: ask ? 11 : 9, style: .continuous))
                .shadow(color: mint && ask ? Self.mint.opacity(0.4) : .clear, radius: 10)
        }
        .buttonStyle(PressableStyle())
    }

    private func bannerButton(_ action: Action) -> some View {
        Button(action: action.run) {
            Text(action.title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .fixedSize()
        }
        .buttonStyle(PressableStyle())
    }
}

/// System Settings panes the cards open.
enum PrivacyPane {
    static let calendars = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let internetAccounts = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
