// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import CoreGraphics
import Foundation
import ImageIO

/// A decoded, display-sized cover. CGImage is immutable, so sharing it across actors is safe.
struct CoverImage: @unchecked Sendable {
    let image: CGImage
}

/// Cover art by URL, kept in memory for the few most recent tracks.
/// `https` URLs are fetched without cookies or a disk cache; other URLs must be `put` by their provider.
/// Decoding and downsampling happen here, off the main actor.
actor ArtworkCache {
    static let shared = ArtworkCache()
    /// Key scheme for artwork a provider hands over as raw bytes (Apple Music).
    static let localScheme = "orilio-artwork"
    /// The largest cover on screen is 96 pt; 2x for Retina.
    static let maxPixelSize = 192

    private var bytes: [URL: Data] = [:]
    private var decoded: [URL: CoverImage] = [:]
    private var order: [URL] = []
    private let limit = 24
    private let session = URLSession(configuration: .ephemeral)

    func put(_ data: Data, for url: URL) {
        remember(url)
        bytes[url] = data
        decoded[url] = nil
    }

    func image(for url: URL) async -> CoverImage? {
        if let cached = decoded[url] { return cached }
        guard let data = await data(for: url), let cover = Self.decode(data) else { return nil }
        remember(url)
        decoded[url] = cover
        return cover
    }

    private func data(for url: URL) async -> Data? {
        if let cached = bytes[url] { return cached }
        guard url.scheme == "https",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        remember(url)
        bytes[url] = data
        return data
    }

    private func remember(_ url: URL) {
        if !order.contains(url) { order.append(url) }
        while order.count > limit {
            let old = order.removeFirst()
            bytes[old] = nil
            decoded[old] = nil
        }
    }

    static func decode(_ data: Data) -> CoverImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true, // decode now, here, not later on the main thread
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(CoverImage.init)
    }
}
