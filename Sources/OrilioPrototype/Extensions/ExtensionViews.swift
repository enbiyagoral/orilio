// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import OrilioExtensionKit
import SwiftUI

// Orilio's own components for what extensions return (the Extensions · ExtPrayer design). Extensions
// never draw: these views are the only way their data reaches the screen.

/// The extension accent: the design's #7DFFD6.
private let extensionMint = Color(red: 0x7D / 255, green: 1, blue: 0xD6 / 255)

/// Icons extensions may name, mapped to Orilio's set. Anything else is left out.
enum ExtensionIcons {
    static let map: [String: String] = [
        "sunrise": "sunrise", "sunset": "sunset", "sun": "sun.max", "moon": "moon", "clock": "clock", "bell": "bell",
        "calendar": "calendar", "star": "star", "location": "location", "cloud": "cloud", "bolt": "bolt",
        "chart": "chart.line.uptrend.xyaxis", "timer": "timer", "check": "checkmark.circle", "warning": "exclamationmark.triangle",
    ]
    static func symbol(_ name: String?) -> String? { name.flatMap { map[$0] } }
}

/// Tints extensions may ask for, clamped to the theme: mint, blue, amber or white.
enum ExtensionTint {
    static func color(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "mint", "#7dffd6", "#2bffb8": extensionMint
        case "blue", "#8dbbff": Color(red: 0x8D / 255, green: 0xBB / 255, blue: 1)
        case "amber", "#ffb86b": SettingsDesign.amber
        default: .white
        }
    }
}

/// "2 h 55 min", "42 min": what's left, rounded up so it never reads 0 before the time. Never "02:55",
/// which reads as a time of day.
enum ExtensionCountdown {
    static func parts(to target: Date, from now: Date) -> (hours: Int, minutes: Int) {
        let minutes = max(0, Int((target.timeIntervalSince(now) / 60).rounded(.up)))
        return (minutes / 60, minutes % 60)
    }

    static func text(to target: Date, from now: Date) -> String {
        let (h, m) = parts(to: target, from: now)
        if h == 0 { return String(localized: "\(m) min") }
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }
}

/// The Extensions tab: the first enabled extension with island content.
/// ponytail: one extension at a time; a switcher comes when a second extension exists.
struct ExtensionsPanel: View {
    let host: ExtensionHost

    var body: some View {
        if let ext = host.active.first(where: { $0.result?.island != nil }), let island = ext.result?.island {
            ExtensionIsland(name: ext.manifest.name, island: island)
        } else {
            StatusCard(tone: .empty, symbol: "puzzlepiece.extension", title: "No extension to show",
                       detail: "Install one in Extensions, or turn on “Show in the notch”.",
                       primary: .init("Open Extensions") { ExtensionsWindow.show() })
        }
    }
}

struct ExtensionIsland: View {
    let name: String
    let island: ExtensionResult.Island

    var body: some View {
        let hero = island.sections.compactMap { if case .hero(let h) = $0 { h } else { nil } }.first
        let rows = island.sections.compactMap { if case .list(let r) = $0 { r } else { nil } }.first
        let footnote = island.sections.compactMap { if case .footnote(let t) = $0 { t } else { nil } }.first
        let notice = island.sections.compactMap { if case .notice(let n) = $0 { n } else { nil } }.first
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                StatusCard(tone: .empty, symbol: ExtensionIcons.symbol(notice.icon) ?? "puzzlepiece.extension", title: notice.title,
                           detail: notice.detail ?? "", primary: .init("Extension settings") { ExtensionsWindow.show() })
            } else {
                HStack(alignment: .top, spacing: 24) {
                    if let hero { HeroView(hero: hero).frame(width: 250, alignment: .leading) }
                    if let rows { RowsView(rows: rows) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            HStack(alignment: .lastTextBaseline) {
                if let footnote { Text(L(footnote)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
                Spacer(minLength: 8)
                Text("EXTENSION")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.63)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 8).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .help(String(localized: "\(name) is an extension: it supplies the data, Orilio draws it"))
            }
        }
        // The design's soft mint glow behind the countdown.
        .background(RadialGradient(colors: [extensionMint.opacity(0.16), .clear], center: UnitPoint(x: 0.18, y: 0.7),
                                   startRadius: 0, endRadius: 260).padding(-20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L(name))
    }
}

private struct HeroView: View {
    let hero: ExtensionResult.Section.Hero

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = hero.label {
                Text(label.uppercased(with: Locale.current)).font(.system(size: 11.5, weight: .semibold)).tracking(1.38).foregroundStyle(extensionMint)
            }
            Text(L(hero.title)).font(.system(size: 30, weight: .semibold)).tracking(-0.6).lineLimit(1)
            if let target = hero.countdownTo {
                // A minute is the finest step it shows, so it redraws once a minute.
                TimelineView(.everyMinute) { context in
                    // Big numbers, small units: "2 sa 55 dk".
                    let (h, m) = ExtensionCountdown.parts(to: target, from: max(context.date, Date()))
                    let number = { (n: Int) in Text("\(n)").font(.system(size: 64, weight: .semibold).monospacedDigit()) }
                    let unit = { (u: String) in Text(u).font(.system(size: 24, weight: .semibold)) }
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if h > 0 { number(h) + unit(" " + String(localized: "h", comment: "hours, after a number") + "  ") }
                        if h == 0 || m > 0 { number(m) + unit(" " + String(localized: "min", comment: "minutes, after a number")) }
                    }
                    .tracking(-1.5)
                    .foregroundStyle(extensionMint)
                    .shadow(color: extensionMint.opacity(0.35), radius: 12)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "\(ExtensionCountdown.text(to: target, from: context.date)) left"))
                }
            }
            if let caption = hero.caption {
                Text(L(caption)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .padding(.top, 6)
    }
}

private struct RowsView: View {
    let rows: [ExtensionResult.Section.Row]

    var body: some View {
        // Six rows (a prayer list with Güneş) are a little tighter so they fit the same island.
        let tight = rows.count > 5
        VStack(spacing: tight ? 3 : 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let next = row.state == .next, past = row.state == .past
                HStack {
                    HStack(spacing: 10) {
                        Circle().fill(next ? extensionMint : .white.opacity(past ? 0.4 : 0.25)).frame(width: 6, height: 6)
                        Text(row.title)
                    }
                    Spacer(minLength: 8)
                    Text(row.value).monospacedDigit().foregroundStyle(next ? extensionMint : .white)
                }
                .font(.system(size: 14, weight: next ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(height: tight ? 34 : 40)
                .background(next ? extensionMint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(extensionMint.opacity(next ? 0.6 : 0), lineWidth: 1.5))
                .opacity(past ? 0.45 : 1)
                .accessibilityElement(children: .combine)
                .accessibilityValue(next ? "Next" : past ? "Passed" : "")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The collapsed island's ears for an extension: its text on the left and the countdown on the
/// right, or the countdown alone on the left when music keeps the right ear (the ExtPrayer design).
struct ExtensionEarView: View {
    let content: ExtensionEarContent
    let side: EarSide
    let withMusic: Bool

    var body: some View {
        if let part = ExtensionEarContent.part(content, side: side, withMusic: withMusic) {
            TimelineView(.everyMinute) { context in
                HStack(spacing: 6) {
                    if let symbol = ExtensionIcons.symbol(part.icon) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                    if part.style == "countdown", let target = part.target {
                        Text(ExtensionCountdown.text(to: target, from: max(context.date, Date())))
                            .monospacedDigit()
                    } else {
                        Text(part.text ?? "").lineLimit(1)
                    }
                }
                // A countdown is live: the theme's color, like a meeting's and the music beside it.
                .foregroundStyle(part.style == "countdown" && (part.tint == nil || part.tint == "mint") ? accent(.live) : ExtensionTint.color(part.tint))
            }
        }
    }
}

extension ExtensionEarContent {
    /// The part an ear shows: with music only the leading ear is free, and it takes the countdown.
    static func part(_ content: ExtensionEarContent, side: EarSide, withMusic: Bool) -> ExtensionResult.EarPart? {
        switch side {
        case .leading: withMusic ? content.trailing ?? content.leading : content.leading
        case .trailing: withMusic ? nil : content.trailing
        }
    }
}
