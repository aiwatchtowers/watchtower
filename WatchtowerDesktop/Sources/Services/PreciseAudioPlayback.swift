import AVFoundation
import Foundation

/// The production `AudioPlayback`: an `AVPlayer` over an `AVURLAsset` opened
/// with `AVURLAssetPreferPreciseDurationAndTimingKey`, one code path for every
/// recording (`.aac`, `.caf`, `.m4a`).
///
/// `AVAudioPlayer` estimates an ADTS file's duration from its bitrate (minutes
/// off on an hour-long meeting), and its seeks land by the same estimate, so a
/// scrubber or a voice clip span played the wrong audio. The precise asset
/// scans the file for its real timing; seeks here are exact (zero tolerance).
///
/// `duration` is 0 until the asset's precise duration has loaded (off the
/// main thread, a fraction of a second on an hour-long file) — callers treat 0
/// as "not known yet", as they did before a player existed. A file that turns
/// out unplayable reports it through `playbackError`. Use from the main thread.
final class PreciseAudioPlayback: AudioPlayback {
    private let player: AVPlayer
    /// Internal for tests (posting its end-of-playback notification).
    let item: AVPlayerItem
    private var endObserver: NSObjectProtocol?
    /// Set by the item's end-of-playback notification, cleared by a seek.
    /// Internal (read-only) for tests.
    private(set) var reachedEnd = false
    private var loadError: Error?
    /// The target of the seek in flight: until it lands `currentTime` reads
    /// it, because `AVPlayer.currentTime()` keeps reporting a cancelled
    /// earlier target while a later seek is still running.
    private var pendingSeek: TimeInterval?
    private var seekGeneration = 0
    private(set) var duration: TimeInterval = 0
    /// Resolves once the precise duration (or its failure) is in. Internal
    /// for tests, which await it instead of polling.
    private(set) var durationLoad: Task<Void, Never>?

    /// Throws when there is no readable file at `url` (the audio was deleted
    /// or moved), synchronously, like the `AVAudioPlayer` it replaces; a file
    /// that exists but cannot be decoded surfaces later in `playbackError`.
    init(url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.reachedEnd = true
        }
        durationLoad = Task { @MainActor [weak self] in
            do {
                let time = try await asset.load(.duration)
                guard let self else { return }
                if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                    self.duration = time.seconds
                }
            } catch {
                self?.loadError = error
            }
        }
    }

    deinit {
        durationLoad?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Why the file cannot be played: its duration failed to load, or the
    /// player item failed. Nil while it plays or is still loading.
    var playbackError: Error? {
        if let loadError { return loadError }
        guard item.status == .failed else { return nil }
        return item.error ?? CocoaError(.fileReadCorruptFile)
    }

    var currentTime: TimeInterval {
        get {
            if let pendingSeek { return pendingSeek }
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? max(0, seconds) : 0
        }
        set {
            let target = max(0, newValue)
            reachedEnd = false
            pendingSeek = target
            seekGeneration += 1
            let generation = seekGeneration
            player.seek(to: CMTime(seconds: target, preferredTimescale: 48_000),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.seekGeneration == generation else { return }
                    self.pendingSeek = nil
                }
            }
        }
    }

    /// A seek is still in flight. Internal for tests.
    var isSeeking: Bool { pendingSeek != nil }

    /// Playing: the rate is set, the item has not reached its end and has
    /// not failed. Before the item is ready the rate is already set, so a
    /// just-started player reads as playing.
    var isPlaying: Bool {
        player.rate != 0 && !reachedEnd && playbackError == nil
    }

    /// Starts (or resumes) playback; after a natural end it starts over from
    /// the beginning. False when the file is already known to be unplayable.
    @discardableResult
    func play() -> Bool {
        guard playbackError == nil else { return false }
        if reachedEnd { currentTime = 0 }
        player.play()
        return true
    }

    func pause() {
        player.pause()
    }

    /// Stops for good: the end observer and the duration load go with it.
    func stop() {
        player.pause()
        durationLoad?.cancel()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
