// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import AppKit
import ImageIO
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look inside the island (the M5 Shelf design): the island grows to 560 pt, the file's name
/// and a meta line on top, "Open in <app>" and close; Space or Esc shrinks it back.
struct ShelfQuickLook: View {
    let item: ShelfItem
    let shelf: ShelfModel
    @State private var meta = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(L(meta)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let app = ShelfMeta.defaultApp(for: item.url) {
                    Button {
                        shelf.open([item])
                        shelf.closePreview()
                    } label: {
                        Text("Open in \(app)").font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
                Button { shelf.closePreview() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .help("Close Quick Look (Space)")
                .accessibilityLabel("Close Quick Look")
            }
            ZStack {
                Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255)
                if item.cloud == .local {
                    QuickLookPreview(url: item.url)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Downloading from iCloud…").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .task(id: item.url) { meta = await ShelfMeta.line(for: item) }
    }
}

/// `QLPreviewView`: the same previews as Finder's Quick Look, drawn in the island.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// The preview's meta line: "PDF · 412 KB · from Downloads", "PNG · 2880 × 1800 · 1.1 MB",
/// "Plain text · 8 KB · from Desktop".
enum ShelfMeta {
    /// PDFs and images are named by their extension, everything else by its kind.
    static func kind(of item: ShelfItem) -> String {
        if item.isFolder { return "Folder" }
        let ext = item.url.pathExtension.uppercased()
        if let type = item.contentType, type.conforms(to: .image) || type.conforms(to: .pdf), !ext.isEmpty { return ext }
        let description = item.contentType?.localizedDescription ?? ext
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    static func line(kind: String, pixels: CGSize?, size: Int64?, folder: String?) -> String {
        var parts = [kind]
        if let pixels { parts.append("\(Int(pixels.width)) × \(Int(pixels.height))") }
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if pixels == nil, let folder, !folder.isEmpty { parts.append("from \(folder)") }
        return parts.joined(separator: " · ")
    }

    /// Reads an image's pixel size from its header (not the whole image), off the main actor.
    static func line(for item: ShelfItem) async -> String {
        let url = item.url, isImage = item.contentType?.conforms(to: .image) == true
        let pixels: CGSize? = await Task.detached(priority: .utility) {
            guard isImage, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGSize(width: width, height: height)
        }.value
        let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
        return line(kind: kind(of: item), pixels: pixels, size: item.size, folder: folder)
    }

    /// "Preview", "TextEdit": the app that opens the file by default.
    @MainActor static func defaultApp(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}
