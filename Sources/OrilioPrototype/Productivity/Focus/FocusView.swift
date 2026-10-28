import SwiftUI

// Values follow the M3 hub design: a 176 pt ring (radius 76, 10 pt stroke), 32 pt preset chips
// (radius 16), a 44 pt main button (radius 14) and a row of 8 pt session dots.
private enum Design {
    static let ink = Color(red: 0, green: 0.078, blue: 0.051) // #00140D, on the accent
    static let track = Color.white.opacity(0.1)
}

/// The Focus module in the island.
struct FocusPanel: View {
    let module: FocusModule
    @State private var customOpen = false

    var body: some View {
        HStack(spacing: 28) {
            // Redrawn once a second only while running, and only the ring and the time.
            TimelineView(.animation(minimumInterval: 1, paused: !module.isRunning)) { context in
                FocusRing(module: module, now: module.isRunning ? context.date : module.now())
            }
            .frame(width: 176, height: 176)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deep work").font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("Keeps running when the island closes — the ring lives in the notch.")
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
                            .background(mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: mint.opacity(0.4), radius: 12)
                    }
                    .buttonStyle(PressableStyle())
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
                        .tint(mint)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let remaining = module.remaining(at: now)
        ZStack {
            Circle().stroke(Design.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: module.fraction(at: now))
                .stroke(mint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: mint.opacity(module.isRunning ? 0.45 : 0), radius: 10)
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
                Circle().fill(index < count ? mint : .white.opacity(0.2)).frame(width: 8, height: 8)
            }
            if count > FocusModule.dailyGoal {
                Text("+\(count - FocusModule.dailyGoal)").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) focus \(count == 1 ? "session" : "sessions") completed today")
    }
}
