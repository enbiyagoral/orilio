import Foundation

/// Image bytes by URL, kept in memory for the few most recent tracks.
/// `https` URLs are fetched without cookies or a disk cache; other URLs must be `put` by their provider.
actor ArtworkCache {
    static let shared = ArtworkCache()
    /// Key scheme for artwork a provider hands over as raw bytes (Apple Music).
    static let localScheme = "orilio-artwork"

    private var images: [URL: Data] = [:]
    private var order: [URL] = []
    private let limit = 24
    private let session = URLSession(configuration: .ephemeral)

    func put(_ data: Data, for url: URL) {
        if images[url] == nil { order.append(url) }
        images[url] = data
        while order.count > limit { images[order.removeFirst()] = nil }
    }

    func data(for url: URL) async -> Data? {
        if let cached = images[url] { return cached }
        guard url.scheme == "https",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        put(data, for: url)
        return data
    }
}
