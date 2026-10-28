import AppKit
import SwiftUI
import Testing
@testable import OrilioPrototype

/// ORILIO_RENDER_ONBOARDING=/path/dir swift test --filter OnboardingRender
/// Draws the four steps at the design's 760 × 480 for a side-by-side check.
@MainActor
struct OnboardingRender {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_RENDER_ONBOARDING"] != nil))
    func renderEveryStep() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_RENDER_ONBOARDING"]!)
        let defaults = UserDefaults(suiteName: "orilio.render.\(UUID().uuidString)")!
        let flow = OnboardingModel(modules: ModuleSettings(defaults: defaults), defaults: defaults, loginStatus: .enabled)
        for step in 0...OnboardingModel.lastStep {
            let view = OnboardingView(model: flow, floating: false) {}
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 44, bottomTrailingRadius: 44).fill(.black))
                .environment(\.colorScheme, .dark).foregroundStyle(.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "step\(step).png"))
            if step < OnboardingModel.lastStep { _ = flow.next() }
        }
    }
}
