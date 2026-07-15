import Foundation
import XCTest
@testable import WatchtowerDesktop

private final class FakePlayback: AudioPlayback {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval
    private(set) var isPlaying = false
    private(set) var playCalls = 0
    private(set) var stopCalls = 0

    init(duration: TimeInterval = 10) {
        self.duration = duration
    }

    @discardableResult
    func play() -> Bool {
        playCalls += 1
        isPlaying = true
        return true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        stopCalls += 1
        isPlaying = false
    }
}

private struct FakePlaybackError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class AudioPlaybackCenterTests: XCTestCase {
    func test_playSetsActiveAndStartsPlaying() {
        let fake = FakePlayback(duration: 20)
        let center = AudioPlaybackCenter { _ in fake }

        center.play(url: URL(fileURLWithPath: "/tmp/rec1.caf"), transcriptID: 1)

        XCTAssertEqual(center.activeTranscriptID, 1)
        XCTAssertTrue(center.isPlaying)
        XCTAssertEqual(center.duration, 20)
        XCTAssertEqual(fake.playCalls, 1)
    }

    func test_playingSecondRecordingStopsFirst() {
        let first = FakePlayback()
        let second = FakePlayback()
        var call = 0
        let center = AudioPlaybackCenter { _ in
            call += 1
            return call == 1 ? first : second
        }

        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        center.play(url: URL(fileURLWithPath: "/tmp/b.caf"), transcriptID: 2)

        XCTAssertEqual(first.stopCalls, 1)
        XCTAssertEqual(center.activeTranscriptID, 2)
        XCTAssertTrue(center.isPlaying)
    }

    func test_playFailureSurfacesErrorWithoutRestoringPrevious() {
        let good = FakePlayback()
        var alreadyPlayed = false
        let center = AudioPlaybackCenter { _ in
            if alreadyPlayed { throw FakePlaybackError() }
            alreadyPlayed = true
            return good
        }

        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        center.play(url: URL(fileURLWithPath: "/tmp/bad.caf"), transcriptID: 2)

        XCTAssertNil(center.activeTranscriptID)
        XCTAssertEqual(center.failedTranscriptID, 2)
        XCTAssertEqual(center.errorMessage, "boom")
        XCTAssertFalse(center.isPlaying)
    }

    func test_pauseStopsPlayingWithoutClearingActive() {
        let fake = FakePlayback()
        let center = AudioPlaybackCenter { _ in fake }
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)

        center.pause()

        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.activeTranscriptID, 1)
        XCTAssertFalse(fake.isPlaying)
    }

    func test_resumeAfterPauseReusesSamePlayerNotFactory() {
        var factoryCalls = 0
        let fake = FakePlayback()
        let center = AudioPlaybackCenter { _ in
            factoryCalls += 1
            return fake
        }
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        center.pause()

        center.resume()

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(center.isPlaying)
        XCTAssertEqual(fake.playCalls, 2)
    }

    func test_resumeAfterNaturalFinishRestartsFromZero() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter { _ in fake }
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        fake.currentTime = 10
        fake.pause() // simulates AVAudioPlayer's own isPlaying flipping false at natural end
        center.refreshProgress()

        center.resume()

        XCTAssertEqual(fake.currentTime, 0)
        XCTAssertEqual(center.currentTime, 0)
        XCTAssertTrue(center.isPlaying)
    }

    func test_seekClampsToDurationRange() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter { _ in fake }
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)

        center.seek(to: 999)
        XCTAssertEqual(center.currentTime, 10)

        center.seek(to: -5)
        XCTAssertEqual(center.currentTime, 0)
    }

    // Degenerate: no active player yet — every control must no-op, not crash.
    func test_operationsWithNoActivePlayerAreNoops() {
        let center = AudioPlaybackCenter { _ in FakePlayback() }

        center.pause()
        center.resume()
        center.seek(to: 5)
        center.refreshProgress()

        XCTAssertNil(center.activeTranscriptID)
        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.currentTime, 0)
    }

    func test_refreshProgressReadsCurrentTimeFromPlayer() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter { _ in fake }
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        fake.currentTime = 4.5

        center.refreshProgress()

        XCTAssertEqual(center.currentTime, 4.5)
    }

    func test_refreshProgressDetectsNaturalFinish() {
        let fake = FakePlayback(duration: 10)
        let center = AudioPlaybackCenter { _ in fake }
        center.play(url: URL(fileURLWithPath: "/tmp/a.caf"), transcriptID: 1)
        fake.currentTime = 10
        fake.pause() // simulates the player's own isPlaying flipping false, not a user pause

        center.refreshProgress()

        XCTAssertFalse(center.isPlaying)
    }
}
