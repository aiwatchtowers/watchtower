import AVFoundation
import XCTest
@testable import WatchtowerDesktop

/// The production player over real files. Tests that start playback mute
/// the `AVPlayer` first (`player.isMuted`), so nothing is heard; positions
/// are read from the `AVPlayer` itself, never from the adapter's in-flight
/// seek target.
@MainActor
final class PreciseAudioPlaybackTests: XCTestCase {
    private let packetSeconds = 1024 / AACFixture.sampleRate
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

    /// Where the `AVPlayer` really is, not the adapter's pending target.
    private func playerSeconds(_ playback: PreciseAudioPlayback) -> TimeInterval {
        playback.player.currentTime().seconds
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) async {
        await fulfillment(of: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil
        )], timeout: timeout)
    }

    /// `AVAudioFile`'s frame count without the ADTS encoder priming the
    /// precise asset trims (none for CAF/MP4, whose packet table trims it).
    private func trimmedFileSeconds(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let frames = file.length - AudioFileDecoder.adtsPrimingFrames(of: file, at: url)
        return Double(frames) / file.processingFormat.sampleRate
    }

    // MARK: duration

    func testDurationMatchesTheFileInEveryRecordingContainer() async throws {
        for ext in ["aac", "caf", "m4a"] {
            let url = try fixture(ext)
            let playback = try PreciseAudioPlayback(url: url)
            XCTAssertEqual(playback.duration, 0, "\(ext): unknown until loaded")
            await playback.durationLoad?.value
            XCTAssertEqual(playback.duration, try trimmedFileSeconds(url), accuracy: packetSeconds, ext)
            XCTAssertNil(playback.playbackError, ext)
            playback.stop()
        }
    }

    /// The guard for the bug this player fixes: on an ADTS file whose packet
    /// sizes vary (silence, then noise), `AVAudioPlayer` extrapolates the
    /// duration from the first packets' bitrate and is far off; this player
    /// matches the file within one packet, and a seek late in the file
    /// lands exactly.
    func testDurationAndALateSeekAreExactWhereAVAudioPlayerEstimates() async throws {
        let url = try AACFixture.writeSilenceThenNoise(silenceSec: 25, noiseSec: 10, fileExtension: "aac")
        cleanup.append(url)
        let truth = try trimmedFileSeconds(url)
        XCTAssertEqual(truth, 35, accuracy: packetSeconds)

        let estimated = try AVAudioPlayer(contentsOf: url).duration
        XCTAssertGreaterThan(abs(estimated - truth), 1, "the fixture must defeat a bitrate estimate (got \(estimated) s)")

        let playback = try PreciseAudioPlayback(url: url)
        await playback.durationLoad?.value
        XCTAssertEqual(playback.duration, truth, accuracy: packetSeconds)

        playback.currentTime = 33.25
        await waitUntil(5) { !playback.isSeeking }
        XCTAssertEqual(playerSeconds(playback), 33.25, accuracy: 0.001)
        playback.stop()
    }

    // MARK: seeking

    /// Production order (`ClipPlayer.play`): create, then seek at once — no
    /// await in between, so the item is not ready yet. The player itself
    /// must land on the target.
    func testASeekRightAfterCreationLandsExactly() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac", durationSec: 5))
        playback.currentTime = 3.21
        await waitUntil(5) { !playback.isSeeking }
        XCTAssertEqual(playerSeconds(playback), 3.21, accuracy: 0.001)
        playback.stop()
    }

    /// Create → seek → play at once: playback starts from the target, not
    /// from 0 (reaching past 6 s from 0 would take longer than the timeout).
    func testSeekThenPlayStartsFromTheTarget() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac", durationSec: 10))
        playback.player.isMuted = true
        playback.currentTime = 6
        XCTAssertTrue(playback.play())
        await waitUntil(3) { self.playerSeconds(playback) > 6.05 }
        let position = playerSeconds(playback)
        XCTAssertGreaterThanOrEqual(position, 6)
        XCTAssertLessThan(position, 7.5)
        playback.stop()
    }

    /// While seeks are in flight `currentTime` reports the latest requested
    /// target — `AVPlayer` alone keeps reporting a cancelled earlier one —
    /// and the player then lands on that latest target.
    func testBackToBackSeeksReportAndLandOnTheLatestTarget() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac"))
        await playback.durationLoad?.value
        playback.currentTime = 1.234
        playback.currentTime = -1
        XCTAssertEqual(playback.currentTime, 0, "a negative target is clamped")
        playback.currentTime = 2.5
        XCTAssertEqual(playback.currentTime, 2.5, accuracy: 0.001)

        await waitUntil(5) { !playback.isSeeking }
        XCTAssertEqual(playerSeconds(playback), 2.5, accuracy: 0.001)
        playback.stop()
    }

    // MARK: failures

    func testAMissingFileThrowsNoSuchFile() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).aac")
        XCTAssertThrowsError(try PreciseAudioPlayback(url: missing)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }

    func testAnUnreadableFileThrowsNoPermission() throws {
        let url = try fixture("aac", durationSec: 0.5)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try PreciseAudioPlayback(url: url)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoPermission)
        }
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

    /// `stop()` cancels the duration load; that cancellation is not the
    /// file's fault and must not read as a playback error.
    func testStopDoesNotInventAPlaybackError() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac"))
        playback.stop()
        await playback.durationLoad?.value
        XCTAssertNil(playback.playbackError)
    }

    // MARK: end of playback

    /// Playing reads as playing; the item's end stops it; `play()` after the
    /// end starts over from 0; after `stop()` the end observer is gone.
    func testEndOfItemStopsPlayingAndPlayAfterTheEndStartsOver() async throws {
        let playback = try PreciseAudioPlayback(url: fixture("aac"))
        playback.player.isMuted = true
        await playback.durationLoad?.value
        XCTAssertTrue(playback.play())
        XCTAssertTrue(playback.isPlaying)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playback.item)
        XCTAssertTrue(playback.reachedEnd)
        XCTAssertFalse(playback.isPlaying, "the end stops it even while the rate is still set")

        XCTAssertTrue(playback.play())
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertFalse(playback.reachedEnd)
        XCTAssertTrue(playback.isPlaying)
        await waitUntil(5) { !playback.isSeeking }
        XCTAssertLessThan(playerSeconds(playback), 1, "the player itself went back to the start")

        playback.stop()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playback.item)
        XCTAssertFalse(playback.reachedEnd, "stop() removed the observer")
    }
}
