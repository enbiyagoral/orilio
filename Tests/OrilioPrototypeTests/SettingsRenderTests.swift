import AppKit
import SwiftUI
import Testing
@testable import OrilioPrototype

/// ORILIO_RENDER_SETTINGS=/path/dir swift test --filter SettingsRender
/// Draws each Settings pane for a side-by-side check against the M4 Settings design.
@MainActor
struct SettingsRender {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORILIO_RENDER_SETTINGS"] != nil))
    func renderEveryPane() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORILIO_RENDER_SETTINGS"]!)
        AppModules.modules = ModuleSettings(defaults: UserDefaults(suiteName: "orilio.render.\(UUID().uuidString)")!)
        for pane in SettingsView.Pane.allCases {
            let renderer = ImageRenderer(content: SettingsView(pane: pane, scrolls: false))
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "\(pane.rawValue).png"))
        }
    }
}
