import Foundation

/// Clearly-labelled fake source for development and tests. Plays no audio and talks to no app.
actor DemoMediaProvider: MediaProvider {
    static let providerID = "demo"
    nonisolated let id = DemoMediaProvider.providerID
    nonisolated let displayName = "Demo"
    nonisolated let updates: AsyncStream<MediaProviderUpdate>
    private let continuation: AsyncStream<MediaProviderUpdate>.Continuation

    private static let tracks: [(title: String, artist: String, album: String, duration: TimeInterval)] = [
        ("Midnight Bloom", "Northlight", "Demo Library", 200),
        ("Soft Horizon", "Atelier Waves", "Demo Library", 187),
        ("Night Drive", "Somber Sky", "Demo Library", 243),
    ]
    private var enabled: Bool
    private var index = 0
    private var state = PlaybackState.paused
    private var position: TimeInterval = 72
    private var positionDate = Date()

    init(enabled: Bool = true) {
        self.enabled = enabled
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let first = Self.snapshot(index: 0, state: .paused, position: 72, positionDate: Date())
        continuation.yield(Self.update(enabled: enabled, snapshot: enabled ? first : nil))
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        publish()
    }

    func perform(_ command: MediaCommand, on sourceID: String) async throws(MediaError) {
        guard enabled, sourceID == Self.providerID else { throw .sessionGone }
        let now = Date()
        if state == .playing { position += now.timeIntervalSince(positionDate) }
        positionDate = now
        switch command {
        case .play: state = .playing
        case .pause: state = .paused
        case .togglePlayPause: state = state == .playing ? .paused : .playing
        case .next: skip(1)
        case .previous: skip(-1)
        case .seek(let to): position = max(0, to)
        case .focus: break
        }
        position = min(position, Self.tracks[index].duration)
        publish()
    }

    private func skip(_ step: Int) {
        index = (index + step + Self.tracks.count) % Self.tracks.count
        position = 0
    }

    private func publish() {
        continuation.yield(Self.update(enabled: enabled, snapshot: enabled ? Self.snapshot(index: index, state: state, position: position, positionDate: positionDate) : nil))
    }

    private nonisolated static func update(enabled: Bool, snapshot: MediaSessionSnapshot?) -> MediaProviderUpdate {
        MediaProviderUpdate(status: enabled ? .ready : .notRunning, sessions: snapshot.map { [$0] } ?? [])
    }

    private nonisolated static func snapshot(index: Int, state: PlaybackState, position: TimeInterval,
                                             positionDate: Date) -> MediaSessionSnapshot {
        let track = tracks[index]
        return MediaSessionSnapshot(
            sourceID: Self.providerID, providerID: Self.providerID, sourceName: "Demo",
            title: track.title, artist: track.artist, album: track.album, artworkURL: nil,
            state: state, duration: track.duration, position: position, positionDate: positionDate,
            capabilities: [.playPause, .next, .previous, .seek], updatedAt: Date(), expiresAt: nil)
    }
}
