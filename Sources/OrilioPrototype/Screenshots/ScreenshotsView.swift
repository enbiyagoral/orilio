import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Screenshots section: a toolbar and a recycling grid (`ScreenshotGrid`) that scrolls inside
/// the panel. Each visible cell shows a small cached JPEG preview; full images are never decoded.
struct ScreenshotsView: View {
    let library: ScreenshotLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if library.items.isEmpty && library.importing == 0 {
                EmptyLibrary(library: library)
            } else {
                ScreenshotGrid(library: library)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Sort", selection: Binding(get: { library.newestFirst }, set: { library.newestFirst = $0 })) {
                    Text("Newest First").tag(true)
                    Text("Oldest First").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label(library.newestFirst ? "Newest" : "Oldest", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(Metrics.secondaryText))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Sort order")

            if library.importing > 0 {
                ProgressView().controlSize(.mini)
                Text("Importing \(library.importing)…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(Metrics.secondaryText))
            }
            Spacer()
            ToolbarButton(symbol: "doc.on.clipboard", label: "Paste") { library.paste() }
            ToolbarButton(symbol: "square.and.arrow.down", label: "Import…") { importPanel() }
            ToolbarButton(symbol: "camera.viewfinder", label: "Capture") { library.captureScreenshot() }
        }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose screenshots to add. Orilio keeps its own copies; the originals stay where they are."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK { library.importFiles(panel.urls) }
        }
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct EmptyLibrary: View {
    @Environment(\.islandLayout) private var layout
    let library: ScreenshotLibrary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "photo.stack")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
            Text("Your screenshot library")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Drop images on \(layout.place), paste with ⌘V, or capture one. Orilio keeps its own copies.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(Metrics.secondaryText))
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(shape.strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}
