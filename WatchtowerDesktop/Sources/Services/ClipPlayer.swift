import AVFoundation
import Observation
import WatchtowerCore

/// Plays one time range of a recording straight from the `.caf` — no clip
/// files are ever written (spec §3.1). A view-local helper, not an
/// AppState-owned center: a clip preview is scoped to whichever Voices card
/// is on screen and has no state worth surviving navigation away from it.
/// Observable so a clip row can show whether it is the one playing.
@MainActor
@Observable
final class ClipPlayer {
    @ObservationIgnored private let playerFactory: (URL) throws -> AudioPlayback
    @ObservationIgnored private var player: AudioPlayback?
    @ObservationIgnored private var timer: Timer?
    private(set) var playingSpan: ClipSpan?
    /// The recording `playingSpan` belongs to — two cards can hold the same
    /// span of different recordings.
    private(set) var playingURL: URL?

    init(playerFactory: @escaping (URL) throws -> AudioPlayback = { try AVAudioPlayer(contentsOf: $0) }) {
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
    /// own (`tick`). A load/play failure leaves nothing playing.
    func play(url: URL, span: ClipSpan) {
        stop()
        guard let p = try? playerFactory(url) else { return }
        p.currentTime = span.start
        guard p.play() else { return }
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
        guard let p = player, let s = playingSpan else { return }
        if p.currentTime >= s.end || !p.isPlaying { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingSpan = nil
        playingURL = nil
    }
}
