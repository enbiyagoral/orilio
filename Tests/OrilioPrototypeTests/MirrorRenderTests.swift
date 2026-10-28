import AppKit
import SwiftUI
import Testing
@testable import OrilioPrototype

/// ORILIO_RENDER_MIRROR=/path/dir swift test --filter MirrorRender
/// Draws the mirror's cards at the design's sizes for a side-by-side check (no camera is used).
@MainActor
struct MirrorRender {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_RENDER_MIRROR"] != nil))
    func renderTheCards() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_RENDER_MIRROR"]!)
        let mirror = CameraMirrorModel(defaults: UserDefaults(suiteName: "orilio.render.\(UUID().uuidString)")!, observeSystem: false)
        mirror.send(.shown(.notDetermined))
        try render(MirrorView(mirror: mirror, hoverOnly: false) {}, size: CGSize(width: 520, height: 260), to: directory.appending(path: "consent.png"))
        mirror.send(.hidden)
        mirror.send(.shown(.denied))
        try render(MirrorView(mirror: mirror, hoverOnly: false) {}, size: CGSize(width: 520, height: 260), to: directory.appending(path: "denied.png"))
    }

    private func render(_ view: some View, size: CGSize, to url: URL) throws {
        let content = view.frame(width: size.width, height: size.height).background(.black)
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
