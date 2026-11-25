import Foundation
import AVFoundation

/// The playback surface `AudioPlaybackCenter` and `ClipPlayer` drive, so
/// both are unit-testable without touching real audio hardware/files. The
/// production one is `PreciseAudioPlayback`.
protocol AudioPlayback: AnyObject {
    /// Setting it seeks (exactly, in the production player).
    var currentTime: TimeInterval { get set }
    /// 0 while not known yet: the production player loads it after creation.
    var duration: TimeInterval { get }
    /// False once playback ended on its own, was paused, or failed.
    var isPlaying: Bool { get }
    /// Why the file cannot be played, found after creation. Nil by default.
    var playbackError: Error? { get }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AudioPlayback {
    var playbackError: Error? { nil }
}

/// App-wide, single-slot registry for meeting-recording audio playback.
///
/// Only one recording plays at a time app-wide — starting a new `play()`
/// always stops/releases whatever was playing first. State lives here (never
/// view-local) so playback for a transcript row behaves consistently
/// regardless of which view embeds its control, matching the
/// `MeetingRecorderCenter`/`TargetExtractCenter` "survives navigation" pattern.
@MainActor
@Observable
final class AudioPlaybackCenter {
    /// The transcript whose audio is loaded (playing or paused). `nil` when idle.
    private(set) var activeTranscriptID: Int64?
    /// The transcript whose most recent `play()` attempt failed to load.
    /// Cleared on the next successful `play()`.
    private(set) var failedTranscriptID: Int64?
    private(set) var errorMessage: String?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AudioPlayback?
    private var timer: Timer?
    private let playerFactory: (URL) throws -> AudioPlayback

    init(playerFactory: @escaping (URL) throws -> AudioPlayback = { try PreciseAudioPlayback(url: $0) }) {
        self.playerFactory = playerFactory
    }

    /// Loads `url` and starts playing immediately, stopping any currently
    /// active playback first (single-active invariant). On failure the
    /// previous playback stays stopped — it is not restored — and
    /// `failedTranscriptID`/`errorMessage` surface the problem to whichever
    /// row attempted it.
    func play(url: URL, transcriptID: Int64) {
        stopCurrent()
        do {
            let newPlayer = try playerFactory(url)
            player = newPlayer
            activeTranscriptID = transcriptID
            failedTranscriptID = nil
            errorMessage = nil
            duration = newPlayer.duration
            currentTime = 0
            newPlayer.play()
            isPlaying = true
            startTimer()
        } catch {
            player = nil
            activeTranscriptID = nil
            failedTranscriptID = transcriptID
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    /// Pauses the active player without releasing it — `resume()` continues
    /// from the same position. No-op when nothing is active.
    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        stopTimer()
    }

    /// Resumes the active (paused) player. If it already finished playing
    /// naturally (`currentTime` caught up to `duration`), restarts from 0
    /// instead of a silent no-op replay. No-op when nothing is active.
    func resume() {
        guard let player else { return }
        if duration > 0 && currentTime >= duration {
            player.currentTime = 0
            currentTime = 0
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    /// Seeks the active player, clamped to `[0, duration]` — only from below
    /// while the duration is not known yet (a scrub that starts playback
    /// seeks before it loads). No-op when nothing is active.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = duration > 0 ? min(max(0, time), duration) : max(0, time)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Pulls `currentTime` (and the duration, once the player has loaded
    /// it) from the active player, detects natural end-of-playback (the
    /// player stopped itself without `pause()` being called), and reports a
    /// file found unplayable after it was opened as this row's failure.
    /// Driven by a timer during real playback; exposed (not `private`) so
    /// tests can call it directly instead of spinning a `RunLoop` to let a
    /// real `Timer` fire.
    func refreshProgress() {
        guard let player else { return }
        if let error = player.playbackError {
            let failed = activeTranscriptID
            stopCurrent()
            failedTranscriptID = failed
            errorMessage = error.localizedDescription
            return
        }
        if player.duration != duration { duration = player.duration }
        currentTime = player.currentTime
        if isPlaying && !player.isPlaying {
            isPlaying = false
            stopTimer()
        }
    }

    private func stopCurrent() {
        player?.stop()
        player = nil
        activeTranscriptID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
