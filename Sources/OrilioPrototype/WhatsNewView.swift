import AppKit
import SwiftUI

private typealias Design = SettingsDesign

/// The M5 System design's What's New: a 600 pt card with the notch on top, three items and Continue.
struct WhatsNewView: View {
    let notes: WhatsNew
    let close: () -> Void

    private static let background = Design.adaptive(dark: Design.ns(0x17171B), light: .white)
    private static let headerTop = Design.adaptive(dark: Design.ns(0x0E1A22), light: Design.ns(0xEAF7F2))
    private static let blueTile = Design.adaptive(dark: NSColor(srgbRed: 110 / 255, green: 168 / 255, blue: 1, alpha: 0.16),
                                                  light: NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.12))
    private static let blueInk = Design.adaptive(dark: Design.ns(0x8DBBFF), light: Design.ns(0x0A64D8))
    private static let neutralTile = Design.adaptive(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.05))
    private static let continueFill = Design.primaryFill
    private static let continueInk = Design.primaryText

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notes.items, id: \.title) { item in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(ink(item.tint))
                            .frame(width: 40, height: 40)
                            .background(tile(item.tint), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 15, weight: .semibold))
                            Text(item.body).font(.system(size: 13)).lineSpacing(13 * 0.45 - 2)
                                .foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                }
                HStack {
                    Spacer()
                    Button(action: close) {
                        Text("Continue").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Self.continueInk)
                            .padding(.horizontal, 22)
                            .frame(height: 40)
                            .background(Self.continueFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 10, leading: 32, bottom: 28, trailing: 32))
        }
        .frame(width: 600)
        .foregroundStyle(Design.ink)
        .background(Self.background)
    }

    private var header: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Self.headerTop, Self.background], startPoint: .top, endPoint: .bottom)
            EllipticalGradient(colors: [Design.mint.opacity(0.22), Design.mint.opacity(0)], center: .top,
                               startRadiusFraction: 0, endRadiusFraction: 0.6)
            // The island, holding three files.
            HStack(spacing: 10) {
                ForEach(Array([[0xE9E5DC, 0xBDB6A8], [0x6F5180, 0x2F6E6C], [0x3A3F4C, 0x20232B]].enumerated()), id: \.offset) { _, pair in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Design.hex(UInt32(pair[0])), Design.hex(UInt32(pair[1]))],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                }
            }
            .padding(.top, 16)
            .frame(width: 260, height: 64)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
            .shadow(color: Design.mint.opacity(0.25), radius: 20)
            VStack(spacing: 4) {
                Text("VERSION \(notes.version)").font(.system(size: 12, weight: .semibold)).tracking(2.16).foregroundStyle(Design.accentText)
                Text("What’s new in Orilio").font(.system(size: 30, weight: .semibold)).tracking(-0.9)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 26)
        }
        .frame(height: 200)
        .clipped()
        .accessibilityElement(children: .combine)
    }

    private func tile(_ tint: String?) -> Color {
        switch tint {
        case "mint": Design.accent.opacity(0.12)
        case "blue": Self.blueTile
        default: Self.neutralTile
        }
    }

    private func ink(_ tint: String?) -> Color {
        switch tint {
        case "mint": Design.accentText
        case "blue": Self.blueInk
        default: Design.ink
        }
    }
}

/// What's New in its own small window, once per feature update.
@MainActor
enum WhatsNewWindow {
    private static var window: NSWindow?

    static func show(_ notes: WhatsNew) {
        if window == nil {
            let host = NSHostingController(rootView: WhatsNewView(notes: notes) { WhatsNewWindow.close() })
            let window = NSWindow(contentViewController: host)
            window.title = "What’s New in Orilio"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func close() { window?.close() }
}
