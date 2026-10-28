// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import SwiftUI

// Values follow the M3 hub design: a 176 pt ring (radius 76, 10 pt stroke), 32 pt preset chips
// (radius 16), a 44 pt main button (radius 14) and a row of 8 pt session dots.
private enum Design {
    static let ink = Color(red: 0, green: 0.078, blue: 0.051) // #00140D, on the accent
    static let track = Color.white.opacity(0.1)
}

/// The Focus module in the island.
struct FocusPanel: View {
    @Environment(\.islandLayout) private var layout
    let module: FocusModule
    @State private var customOpen = false

    var body: some View {
        if let ended = module.endedWhileAsleep {
            // The deadline passed while the Mac slept: say when, once, and offer the next one.
            StatusCard(tone: .good, symbol: "moon.zzz", title: "Session ended at \(ended.formatted(date: .omitted, time: .shortened))",
                       detail: "Your Mac was asleep, so Orilio stayed quiet.",
                       primary: .init("Start another") { module.begin() },
                       secondary: .init("Dismiss") { module.dismissEndedNotice() })
        } else if let finished = module.finished {
            FocusEndCard(module: module, finished: finished)
        } else if module.isOnBreak {
            BreakPanel(module: module)
        } else {
            timer
        }
    }

    private var timer: some View {
        HStack(spacing: 28) {
            // Redrawn once a second only while running, and only the ring and the time.
            TimelineView(.animation(minimumInterval: 1, paused: !module.isRunning)) { context in
                FocusRing(module: module, now: module.isRunning ? context.date : module.now())
            }
            .frame(width: 176, height: 176)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deep work").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("Keeps running when the island closes — the ring lives in \(layout.place).")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    ForEach(FocusModule.presets, id: \.self) { preset in
                        Chip(label: "\(preset) min", active: module.minutes == preset) { module.setMinutes(preset) }
                    }
                    let custom = !FocusModule.presets.contains(module.minutes)
                    Chip(label: custom ? "\(module.minutes) min" : "Custom", active: custom) { customOpen = true }
                        .popover(isPresented: $customOpen, arrowEdge: .bottom) {
                            Stepper(module.minutes == 1 ? "1 minute" : "\(module.minutes) minutes",
                                    onIncrement: { module.setMinutes(FocusModule.step(module.minutes, up: true)) },
                                    onDecrement: { module.setMinutes(FocusModule.step(module.minutes, up: false)) })
                                .monospacedDigit()
                                .frame(width: 150, alignment: .leading) // fits "240 minutes"; the popover doesn't resize
                                .padding(14)
                        }
                }
                .disabled(module.isActive)
                .opacity(module.isActive ? 0.5 : 1)
                HStack(spacing: 8) {
                    Button(action: module.toggle) {
                        Text(module.isRunning ? "Pause" : module.isActive ? "Resume" : "Start focus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Design.ink)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(accent(.action), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .themeGlow(.action, radius: 12, opacity: 0.4)
                    }
                    .buttonStyle(PressableStyle())
                    .keyboardFocusRing(true, radius: 14) // ⏎ starts or pauses
                    Button(action: module.reset) {
                        Text("Reset")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!module.isActive)
                    SessionDots(count: module.completedToday).padding(.leading, 10)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Notify me when a session ends", isOn: Binding(
                        get: { module.notify }, set: { on in Task { await module.setNotify(on) } }))
                        .toggleStyle(.checkbox)
                        .tint(accent(.rest))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                    if module.notificationsDenied {
                        Text("Notifications are off for Orilio in System Settings. The timer still runs.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .onAppear { module.refreshDay() }
    }
}

private struct FocusRing: View {
    let module: FocusModule
    let now: Date
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let remaining = module.remaining(at: now)
        ZStack {
            Circle().stroke(Design.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: module.fraction(at: now))
                .stroke(accent(.live), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .themeGlow(.live, radius: 10, opacity: module.isRunning ? 0.45 : 0)
                .animation(reduceMotion ? nil : .linear(duration: 1), value: remaining)
            VStack(spacing: 2) {
                Text(FocusSession.text(remaining))
                    .font(.system(size: 38, weight: .semibold).monospacedDigit())
                    .tracking(-1.1)
                Text(module.stateText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 152, height: 152)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus timer, \(FocusSession.text(remaining)) remaining, \(module.stateText)")
    }
}

private struct Chip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(active ? Color.white.opacity(0.9) : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Sessions completed today: a dot each up to the day's goal, then a count.
private struct SessionDots: View {
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<FocusModule.dailyGoal, id: \.self) { index in
                Circle().fill(index < count ? accent(.rest) : .white.opacity(0.2)).frame(width: 8, height: 8)
            }
            if count > FocusModule.dailyGoal {
                Text("+\(count - FocusModule.dailyGoal)").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) focus \(count == 1 ? "session" : "sessions") completed today")
    }
}

/// The M5 Moments design's session-done and break-over cards: a 40 pt mint ring, the title and a
/// line under it, a mint primary button that fills the row and a quiet second one.
private struct FocusEndCard: View {
    let module: FocusModule
    let finished: FocusModule.Finished

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if case .session = finished {
                    Circle().strokeBorder(accent(.action), lineWidth: 3)
                        .frame(width: 40, height: 40)
                        .themeGlow(.action, radius: 7, opacity: 0.5)
                        .overlay { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(accent(.action)) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.58))
                }
            }
            HStack(spacing: 6) {
                Button(action: primary) {
                    Text(primaryTitle).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Design.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(accent(.action), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .keyboardFocusRing(true)
                Button(action: secondary) {
                    Text(secondaryTitle).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch finished {
        case .session(_, let minutes): minutes == 1 ? "1 minute, done" : "\(minutes) minutes, done"
        case .breakOver: "Break’s over"
        }
    }

    private var detail: String {
        switch finished {
        case .session(let number, _): "Session \(number) of \(FocusModule.cycle)"
        case .breakOver(let next): "Ready for session \(next) of \(FocusModule.cycle)?"
        }
    }

    private var primaryTitle: String {
        switch finished {
        case .session(let number, _): "\(FocusModule.breakMinutes(after: number)) min break"
        case .breakOver: "Start \(module.minutes) min"
        }
    }

    private var secondaryTitle: String {
        if case .session = finished { return "Keep going" }
        return "Done for now"
    }

    private func primary() {
        if case .session = finished { module.startBreak() } else { module.begin() }
    }

    private func secondary() {
        if case .session = finished { module.keepGoing() } else { module.doneForNow() }
    }
}

/// A break running: the ring in the calm blue, so it never reads as work.
private struct BreakPanel: View {
    let module: FocusModule
    static let blue = Color(red: 0x8D / 255, green: 0xBB / 255, blue: 1)

    var body: some View {
        HStack(spacing: 28) {
            TimelineView(.animation(minimumInterval: 1)) { context in
                let remaining = module.breakRemaining(at: context.date)
                let total = module.breakSession?.duration ?? 1
                ZStack {
                    Circle().stroke(Design.track, lineWidth: 10)
                    Circle().trim(from: 0, to: remaining / total)
                        .stroke(Self.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text(FocusSession.text(remaining)).font(.system(size: 38, weight: .semibold).monospacedDigit()).tracking(-1.1)
                        Text("break").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(width: 152, height: 152)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Break, \(FocusSession.text(remaining)) left")
            }
            .frame(width: 176, height: 176)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Break").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("Step away for a moment. The island says when it’s time to go on.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                Button(action: module.endBreak) {
                    Text("End break").font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}
