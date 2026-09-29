import Foundation
@testable import WatchtowerDesktop

/// Shared fake `AudioPlayback` for tests exercising `ClipPlayer` (and any
/// other `AudioPlayback` consumer) without touching real audio hardware or
/// files. `AudioPlaybackCenterTests` keeps its own private `FakePlayback`
/// with call counters that test only need; this one is the plain shared
/// case.
final class FakeAudioPlayback: AudioPlayback {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval
    private(set) var isPlaying = false

    init(duration: TimeInterval = 10) {
        self.duration = duration
    }

    @discardableResult
    func play() -> Bool {
        isPlaying = true
        return true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
    }
}
