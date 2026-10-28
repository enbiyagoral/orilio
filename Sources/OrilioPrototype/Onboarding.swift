// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import Observation
import SwiftUI

/// The first-run flow inside the island (the M5 Onboarding design): Welcome, This is the island,
/// What should live up here?, Always there when you need it. It asks for no permission; the
/// module choices only set visibility.
@MainActor @Observable
final class OnboardingModel {
    static let completedKey = "onboarding.completedVersion"
    static let lastStep = 3
    /// The design's defaults for a new user: everything but Clipboard and Camera Mirror.
    static let defaultModules: Set<IslandTab> = [.calendar, .music, .focus, .notes, .shelf]
    /// The order of the design's module grid.
    static let grid: [IslandTab] = [.calendar, .music, .focus, .notes, .shelf, .clipboard, .mirror]

    private(set) var step = 0
    private(set) var chosen: Set<IslandTab>
    private(set) var login: LoginItem.Status

    @ObservationIgnored private let modules: ModuleSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let version: String
    @ObservationIgnored private let loginItem: (Bool) throws -> LoginItem.Status

    /// Whether this launch should show the flow.
    static func shouldShow(_ defaults: UserDefaults = .standard) -> Bool { defaults.string(forKey: completedKey) == nil }

    /// "Replay onboarding": the next start (or `IslandModel.startOnboarding`) shows it again.
    static func reset(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: completedKey) }

    init(modules: ModuleSettings, defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         loginStatus: LoginItem.Status = LoginItem.status,
         loginItem: @escaping (Bool) throws -> LoginItem.Status = { try LoginItem.set($0); return LoginItem.status }) {
        self.modules = modules
        self.defaults = defaults
        self.version = version
        self.login = loginStatus
        self.loginItem = loginItem
        // Someone who already set up modules starts from their choice, not the design's defaults.
        let configured = defaults.object(forKey: Preferences.key) != nil || defaults.object(forKey: "modules.hidden") != nil
        chosen = configured ? modules.visibleSet : Self.defaultModules
    }

    var primaryTitle: String {
        switch step {
        case 0: "Get started"
        case Self.lastStep: "Done"
        default: "Continue"
        }
    }

    /// Returns true when the flow is finished.
    func next() -> Bool {
        guard step < Self.lastStep else { finish(); return true }
        step += 1
        return false
    }

    func back() { step = max(0, step - 1) }

    /// At least one module always stays on.
    func toggle(_ tab: IslandTab) {
        if chosen.contains(tab) {
            guard chosen.count > 1 else { return }
            chosen.remove(tab)
        } else {
            chosen.insert(tab)
        }
    }

    func setLogin(_ on: Bool) {
        login = (try? loginItem(on)) ?? LoginItem.status
    }

    /// Applies the choices (visibility only, no permission) and remembers the flow was seen. Esc
    /// and closing the island end here too, so there is never a half state.
    func finish() {
        // Extensions aren't a module the flow offers: their tab follows what's installed.
        for tab in IslandTab.allCases where tab != .extensions && chosen.contains(tab) { modules.setVisible(tab, true) }
        for tab in IslandTab.allCases where tab != .extensions && !chosen.contains(tab) { modules.setVisible(tab, false) }
        defaults.set(version, forKey: Self.completedKey)
    }
}

extension IslandTab {
    /// The design's notes on each module tile.
    var onboardingNote: String {
        switch self {
        case .calendar: "Asks for Calendar"
        case .music: "Asks to control Music apps"
        case .focus, .notes, .shelf: "No permission"
        case .clipboard: "Off by default · local only"
        case .mirror: "Asks for Camera"
        case .extensions: "Settings › Extensions"
        }
    }

    var onboardingTitle: String {
        switch self {
        case .calendar: "Calendar"
        case .music: "Now Playing"
        case .focus: "Focus"
        case .notes: "Notes & Tasks"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .mirror: "Camera Mirror"
        case .extensions: "Extensions"
        }
    }
}

// MARK: - The flow

// The M5 Onboarding design, value for value: a 760 × 480 island (bottom radius 44), padding
// 56/56/32/56, a step-dot row and the buttons at the bottom.
private enum Design {
    static let mint = SettingsDesign.mint
    static let ink = SettingsDesign.hex(0x00140D)
    static let size = CGSize(width: 760, height: 480)
    static let radius: CGFloat = 44
}

extension OnboardingModel {
    static var panelSize: CGSize { Design.size }
    static var radius: CGFloat { Design.radius }
}

struct OnboardingView: View {
    @Environment(\.islandLayout) private var layout
    let model: OnboardingModel
    /// No notch on this display: one line says why the island floats.
    let floating: Bool
    let finish: () -> Void
    @FocusState private var focus: Field?

    enum Field: Hashable { case primary, back, login, module(IslandTab) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case 0: welcome
                case 1: island
                case 2: modules
                default: always
                }
            }
            .id(model.step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0...OnboardingModel.lastStep, id: \.self) { index in
                        Capsule()
                            .fill(index == model.step ? Design.mint : .white.opacity(0.25))
                            .frame(width: index == model.step ? 22 : 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(model.step + 1) of 4")
                Spacer()
                HStack(spacing: 8) {
                    if model.step > 0 {
                        FlowButton(title: "Back", primary: false, field: .back, focus: $focus) { model.back() }
                    }
                    FlowButton(title: model.primaryTitle, primary: true, field: .primary, focus: $focus) { advance() }
                }
            }
            .padding(.top, 18)
        }
        .padding(EdgeInsets(top: 56, leading: 56, bottom: 32, trailing: 56))
        .frame(width: Design.size.width, height: Design.size.height)
        .animation(Theme.current.reducesMotion ? nil : .easeOut(duration: 0.42), value: model.step)
        // Return is the primary button wherever the focus is; Esc (the panel) finishes.
        .onKeyPress(.return) {
            advance()
            return .handled
        }
        .onAppear { focus = .primary }
    }

    private func advance() {
        if model.next() { finish() }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            AppMark(size: 88, radius: 24, notch: CGSize(width: 40, height: 13), light: CGSize(width: 18, height: 4))
            VStack(spacing: 10) {
                Text("Welcome to Orilio").font(.system(size: 44, weight: .semibold)).tracking(-1.76)
                Text(floating ? "No notch here, so the island floats at the top of this display. Everything else works the same."
                     : "Everything at the top. Nothing in your way.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 28) {
            Heading(title: "This is the island.", detail: "It grows out of \(layout.place) only when you reach for it.")
            // Three equal columns, as in the design's grid.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), spacing: 14) {
                GestureCard(title: "Hover to peek", detail: "A glance at what is playing or what is next.",
                            island: CGSize(width: 150, height: 40), glow: false, pointer: CGPoint(x: 120, y: 30))
                GestureCard(title: "Click to keep it open", detail: "It stays until you close it or press Esc.",
                            island: CGSize(width: 220, height: 70), glow: true, pointer: CGPoint(x: 128, y: 46))
                GestureCard(title: "Move away to close", detail: "Your work is never covered for long.",
                            island: CGSize(width: 96, height: 18), glow: false, pointer: CGPoint(x: 190, y: 64))
            }
        }
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: 22) {
            Heading(title: "What should live up here?",
                    detail: "Pick a few. Orilio only asks for a permission the first time a module needs it.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(OnboardingModel.grid) { tab in
                    ModuleTile(tab: tab, on: model.chosen.contains(tab), focus: $focus) { model.toggle(tab) }
                }
            }
        }
    }

    private var always: some View {
        VStack(alignment: .leading, spacing: 24) {
            Heading(title: "Always there when you need it.", detail: "You can change all of this later in Settings.")
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "power").font(.system(size: 17, weight: .medium)).foregroundStyle(Design.mint)
                        .frame(width: 38, height: 38)
                        .background(Design.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login").font(.system(size: 15, weight: .semibold))
                        Text(model.login == .requiresApproval ? "Waiting for your approval in System Settings › General › Login Items"
                             : "Starts quietly in \(layout.place). No window, no Dock icon.")
                            .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    DesignSwitch(isOn: model.login != .off, large: true, label: "Open at login") { model.setLogin(model.login == .off) }
                        .focusable()
                        .focused($focus, equals: .login)
                        .onKeyPress(.space) { model.setLogin(model.login == .off); return .handled }
                        .focusRing(focus == .login, radius: 13)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 72)
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                HStack(spacing: 14) {
                    Image(systemName: "keyboard").font(.system(size: 16, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open from the keyboard").font(.system(size: 15, weight: .semibold))
                        Text("Works in any app, even fullscreen.").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach(PreferencesStore.shared.value.shortcut(.toggleIsland).keycaps, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, key == "Space" ? 11 : 9)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PreferencesStore.shared.value.shortcut(.toggleIsland).spoken)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 72)
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
    }
}

private struct Heading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.9)
            Text(detail).font(.system(size: 15)).foregroundStyle(.white.opacity(0.62))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The design's app mark: a dark tile with a notch and a mint light in it.
struct AppMark: View {
    let size: CGFloat
    let radius: CGFloat
    let notch: CGSize
    let light: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [SettingsDesign.hex(0x1B2233), SettingsDesign.hex(0x07080C)],
                                 startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: notch.height * 0.6, bottomTrailingRadius: notch.height * 0.6)
                        .fill(.black).frame(width: notch.width, height: notch.height)
                    Capsule().fill(Design.mint).frame(width: light.width, height: light.height)
                        .shadow(color: Design.mint, radius: 5)
                        .padding(.top, 4)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.5), radius: 20, y: 18)
            .accessibilityHidden(true)
    }
}

/// One of the three gestures: a small scene with the island at that size and the pointer.
private struct GestureCard: View {
    let title: String
    let detail: String
    let island: CGSize
    let glow: Bool
    let pointer: CGPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The scene is as wide as the card; the island and pointer are drawn over it and cut
            // at its edges (the design's 220 pt island is wider than its scene).
            ZStack {
                Rectangle().fill(SettingsDesign.hex(0x141B2D))
                EllipticalGradient(colors: [SettingsDesign.hex(0x2F6E6C), SettingsDesign.hex(0x2F6E6C, 0)],
                                   center: UnitPoint(x: 0, y: 1), startRadiusFraction: 0, endRadiusFraction: 0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black)
                    .frame(width: island.width, height: island.height)
                    .shadow(color: glow ? Design.mint.opacity(0.35) : .clear, radius: 8)
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: "cursorarrow").font(.system(size: 13)).foregroundStyle(.white)
                    .shadow(color: .black, radius: 0.6)
                    .offset(x: pointer.x, y: pointer.y)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).lineSpacing(12.5 * 0.4 - 2).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A module tile: its icon and check, name and permission note; mint when chosen.
private struct ModuleTile: View {
    let tab: IslandTab
    let on: Bool
    var focus: FocusState<OnboardingView.Field?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: tab.symbol).font(.system(size: 19, weight: .regular))
                        .foregroundStyle(on ? Design.mint : .white.opacity(0.7))
                        .frame(width: 22, height: 22)
                    Spacer()
                    ZStack {
                        Circle().fill(on ? Design.mint : .clear)
                        Circle().strokeBorder(.white.opacity(on ? 0 : 0.3), lineWidth: 1.5)
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Design.ink) }
                    }
                    .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.onboardingTitle).font(.system(size: 13.5, weight: .semibold))
                    Text(tab.onboardingNote).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(on ? Design.mint.opacity(0.08) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? Design.mint.opacity(0.7) : .white.opacity(0.08), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focus, equals: .module(tab))
        .onKeyPress(.space) { action(); return .handled }
        .focusRing(focus.wrappedValue == .module(tab), radius: 16)
        .accessibilityLabel("\(tab.onboardingTitle), \(tab.onboardingNote)")
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

/// The footer buttons: Back (10% white) and the mint primary with its glow.
private struct FlowButton: View {
    let title: String
    let primary: Bool
    let field: OnboardingView.Field
    var focus: FocusState<OnboardingView.Field?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? Design.ink : .white)
                .padding(.horizontal, primary ? 22 : 18)
                .frame(height: 44)
                .background(primary ? Design.mint : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: primary ? Design.mint.opacity(0.4) : .clear, radius: 12)
        }
        .buttonStyle(PressableStyle())
        .focusable()
        .focused(focus, equals: field)
        .onKeyPress(.space) { action(); return .handled }
        .focusRing(focus.wrappedValue == field, radius: 14)
    }
}

private extension View {
    /// The design's focus ring: 2 pt of 80% mint, 2 pt outside the control.
    func focusRing(_ shown: Bool, radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
            .strokeBorder(shown ? Design.mint.opacity(0.8) : .clear, lineWidth: 2)
            .padding(-4))
            .focusEffectDisabled()
    }
}

/// After the flow: an up arrow and one line under the notch, once. It fades after 6 s or on the
/// first hover.
struct LivesHereHint: View {
    var layout = IslandLayout.notch

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.up")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Design.mint)
                .shadow(color: Design.mint.opacity(0.6), radius: 4)
            Text("Orilio lives here now. Hover \(layout.place) any time.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 6)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }
}
