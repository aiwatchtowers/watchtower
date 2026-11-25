import AVFoundation
import XCTest
@testable import WatchtowerDesktop

/// The production player over real files. Nothing here starts audio output:
/// duration, seeks and the end-of-playback bookkeeping are read without
/// playing.
@MainActor
final class PreciseAudioPlaybackTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        super.tearDown()
    }

    private func fixture(_ fileExtension: String, durationSec: Double = 3) throws -> URL {
        let url = try AACFixture.write(durationSec: durationSec, fileExtension: fileExtension)
        cleanup.append(url)
        return url
    }

    /// The duration is the file's real one, for ADTS (which `AVAudioPlayer`
    /// estimated from the bitrate) and the legacy containers alike: within
    /// the encoder's priming and padding (a few 1024-frame packets) of the
    /// frames `AVAudioFile` counts.
    func testDurationIsPreciseForEveryRecordingContainer() async throws {
        for ext in ["aac", "caf", "m4a"] {
            let url = try fixture(ext)
            let playback = try PreciseAudioPlayback(url: url)
            XCTAssertEqual(playback.duration, 0, "\(ext): unknown until loaded")
            await playback.durationLoad?.value
            let file = try AVAudioFile(forReading: url)
            let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertEqual(playback.duration, fileSeconds, accuracy: 3 * 1024 / AACFixture.sampleRate, ext)
            XCTAssertEqual(playback.duration, 3, accuracy: 0.2, ext)
            XCTAssertNil(playback.playbackError, ext)
            playback.stop()
        }
    }

    func testSeekIsExact() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac"))
        await playback.durationLoad?.value
        playback.currentTime = 1.234
        XCTAssertEqual(playback.currentTime, 1.234, accuracy: 0.001)
        // A second seek while the first runs: AVPlayer alone would keep
        // reporting the cancelled 1.234 until this one lands.
        playback.currentTime = -1
        XCTAssertEqual(playback.currentTime, 0)
        playback.currentTime = 2.5
        XCTAssertEqual(playback.currentTime, 2.5, accuracy: 0.001)

        await fulfillment(of: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !playback.isSeeking }, object: nil
        )], timeout: 5)
        XCTAssertEqual(playback.currentTime, 2.5, accuracy: 0.001, "the player itself landed on the target")
        playback.stop()
    }

    func testAMissingFileThrowsAtCreation() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).aac")
        XCTAssertThrowsError(try PreciseAudioPlayback(url: missing))
    }

    func testAnUndecodableFileReportsAPlaybackError() async throws {
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).aac")
        try Data("not audio".utf8).write(to: garbage)
        cleanup.append(garbage)
        let playback = try PreciseAudioPlayback(url: garbage)
        await playback.durationLoad?.value
        XCTAssertNotNil(playback.playbackError)
        XCTAssertFalse(playback.play(), "a known-unplayable file must not report a started output")
        XCTAssertFalse(playback.isPlaying)
    }

    /// The end of the item stops `isPlaying` (the centers' natural-finish
    /// signal), and after `stop()` the observer is gone.
    func testEndOfItemStopsPlayingAndStopRemovesTheObserver() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac"))
        await playback.durationLoad?.value
        playback.pause()
        XCTAssertFalse(playback.isPlaying)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playback.item)
        XCTAssertTrue(playback.reachedEnd)
        XCTAssertFalse(playback.isPlaying)
        playback.currentTime = 0.5
        XCTAssertFalse(playback.reachedEnd, "a seek clears the end")

        playback.stop()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playback.item)
        XCTAssertFalse(playback.reachedEnd, "stop() removed the observer")
    }
}
