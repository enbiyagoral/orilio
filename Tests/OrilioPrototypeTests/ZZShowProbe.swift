import AppKit
import SwiftUI
import Testing
@testable import OrilioPrototype

private struct Silent: FocusNotifier {
    func authorize() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func schedule(at date: Date, minutes: Int) async {}
    func cancel() async {}
}

@MainActor struct ZZShowProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_SHOW"] != nil)) func render() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_SHOW"]!)
        let defaults = UserDefaults(suiteName: "orilio.show.\(UUID().uuidString)")!
        var notch = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), safeAreaTop: 32,
                                        auxLeftWidth: 645, auxRightWidth: 646, menuBarHeight: 32)
        var floating = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                           auxLeftWidth: nil, auxRightWidth: nil, menuBarHeight: 25)
        floating.displayName = "DELL U2723QE"
        notch.usableHeight = 900; floating.usableHeight = 1380
        for (name, g) in [("notch", notch), ("floating", floating)] {
            let island = IslandModel(focus: FocusModule(defaults: defaults, notifier: Silent()), modules: ModuleSettings(defaults: defaults))
            island.isPointerBusy = { false }
            island.geometry = g
            island.tab = .focus
            island.set(.pinned)
            let frame = g.windowFrame(for: .pinned)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: frame.size), styleMask: .borderless, backing: .buffered, defer: false)
            let host = NSHostingView(rootView: ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.18, green: 0.3, blue: 0.36), Color(red: 0.12, green: 0.14, blue: 0.24)], startPoint: .top, endPoint: .bottom)
                Color.white.opacity(0.18).frame(height: g.topInset)
                IslandView(model: island)
            })
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            for _ in 0..<25 { try await Task.sleep(for: .milliseconds(20)) }
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: out.appending(path: "\(name).png"))
            window.orderOut(nil)
        }
    }
}
