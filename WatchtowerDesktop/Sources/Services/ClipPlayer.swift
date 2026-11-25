import AVFoundation
import Observation
import os
import WatchtowerCore

/// Plays one time range of a recording straight from the recording file — no clip
/// files are ever written (spec §3.1). A view-local helper, not an
/// AppState-owned center: a clip preview is scoped to whichever Voices card
/// is on screen and has no state worth surviving navigation away from it.
/// Observable so a clip row can show whether it is the one playing.
@MainActor
@Observable
final class ClipPlayer {
    @ObservationIgnored private let playerFactory: @MainActor (URL) throws -> AudioPlayback
    @ObservationIgnored private var player: AudioPlayback?
    @ObservationIgnored private var timer: Timer?
    private(set) var playingSpan: ClipSpan?
    /// The recording `playingSpan` belongs to — two cards can hold the same
    /// span of different recordings.
    private(set) var playingURL: URL?
    /// Why the last clip could not play (the recording is gone, unreadable,
    /// or the output refused to start) — cleared by the next play or stop.
    private(set) var errorMessage: String?

    init(playerFactory: @escaping @MainActor (URL) throws -> AudioPlayback = { try PreciseAudioPlayback(url: $0) }) {
        self.playerFactory = playerFactory
    }

    func isPlaying(url: URL, span: ClipSpan) -> Bool {
        playingURL == url && playingSpan == span
    }

    /// The clip button's action: stops the clip if it is the one playing,
    /// otherwise switches playback to it.
    func toggle(url: URL, span: ClipSpan) {
        if isPlaying(url: url, span: span) {
            stop()
        } else {
            play(url: url, span: span)
        }
    }

    /// Seeks to `span.start` and plays until `span.end`, then stops on its
    /// own (`tick`). A failure leaves nothing playing and is reported through
    /// `errorMessage`: the file cannot be opened (the factory throws), the
    /// player already knows it cannot play it (`play()` returns false — the
    /// production player only when its `playbackError` is set, which right
    /// after creation is rare), or it finds that out while playing (`tick`).
    func play(url: URL, span: ClipSpan) {
        stop()
        let p: AudioPlayback
        do {
            p = try playerFactory(url)
        } catch {
            fail("Can't play this clip: \(error.localizedDescription)", url: url, error: error)
            return
        }
        p.currentTime = span.start
        guard p.play() else {
            fail("Can't play this clip: \(p.playbackError?.localizedDescription ?? "the player refused to start")",
                 url: url, error: p.playbackError)
            return
        }
        player = p
        playingSpan = span
        playingURL = url
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops playback once the span's end is reached (or the player stopped
    /// on its own). Driven by the timer during real playback; exposed (not
    /// `private`) so tests can call it directly instead of spinning a
    /// `RunLoop` to let a real `Timer` fire.
    func tick() {
        guard let p = player, let s = playingSpan, let url = playingURL else { return }
        if let error = p.playbackError {
            stop()
            fail("Can't play this clip: \(error.localizedDescription)", url: url, error: error)
        } else if p.currentTime >= s.end || !p.isPlaying {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingSpan = nil
        playingURL = nil
        errorMessage = nil
    }

    private static let log = Logger(subsystem: Constants.bundleID, category: "playback")

    private func fail(_ message: String, url: URL, error: Error? = nil) {
        let detail = error.map { AudioPlaybackCenter.describe($0) } ?? "-"
        Self.log.error("""
            clip: \(message, privacy: .public) (\(url.lastPathComponent, privacy: .public); \(detail, privacy: .public))
            """)
        errorMessage = message
    }
}
