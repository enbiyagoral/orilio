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

    /// Bytes a provider handed over, until they're decoded; after that only the small cover is kept.
    private var given: [URL: Data] = [:]
    private var decoded: [URL: CoverImage] = [:]
    /// One load per URL: views asking at once wait for the same one.
    private var loading: [URL: Task<CoverImage?, Never>] = [:]
    private var order: [URL] = []
    private let limit = 24
    private let session = URLSession(configuration: .ephemeral)

    func put(_ data: Data, for url: URL) {
        remember(url)
        given[url] = data
        decoded[url] = nil
    }

    func image(for url: URL) async -> CoverImage? {
        if let cached = decoded[url] { return cached }
        if let task = loading[url] { return await task.value }
        let data = given[url], session = session
        let task = Task<CoverImage?, Never> {
            if let data { return Self.decode(data) }
            guard url.scheme == "https", let (fetched, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.decode(fetched)
        }
        loading[url] = task
        let cover = await task.value
        loading[url] = nil
        if let cover {
            remember(url)
            decoded[url] = cover
            given[url] = nil
        }
        return cover
    }

    private func remember(_ url: URL) {
        if !order.contains(url) { order.append(url) }
        while order.count > limit {
            let old = order.removeFirst()
            given[old] = nil
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
