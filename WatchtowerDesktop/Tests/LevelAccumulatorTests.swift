import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Pins `LevelAccumulator` — the ~10 Hz live-level throttle inside
/// `SystemAudioRecorder`'s IO callback. Pure RMS math over raw pre-gain
/// samples (the `MicActivityAccumulator` shape): `flush` yields a pair only
/// once ≥ 0.1 s of frames accumulated, then resets.
final class LevelAccumulatorTests: XCTestCase {

    func testFlushBelowWindowReturnsNil() {
        var acc = LevelAccumulator()
        // 0.05 s at a realistic 48 kHz device rate = 2 400 frames — below the window.
        for _ in 0..<2_400 { acc.add(mic: 0.2, sys: 0.4) }
        XCTAssertNil(acc.flush(sampleRate: 48_000))
    }

    func testFlushAtWindowReturnsRMSAndResets() {
        var acc = LevelAccumulator()
        // 0.1 s at 48 kHz = 4 800 frames of constant mic 0.2 / system 0.4.
        for _ in 0..<4_800 { acc.add(mic: 0.2, sys: 0.4) }
        guard let levels = acc.flush(sampleRate: 48_000) else {
            return XCTFail("0.1 s of frames must flush a level pair")
        }
        XCTAssertEqual(levels.mic, 0.2, accuracy: 0.001)
        XCTAssertEqual(levels.system, 0.4, accuracy: 0.001)
        XCTAssertNil(acc.flush(sampleRate: 48_000),
                     "flush must reset — an immediate second flush has no new frames")
    }

    func testRMSAveragesSquaresNotAmplitudes() {
        var acc = LevelAccumulator()
        // Half silence, half 0.2 → mean square 0.02, RMS = sqrt(0.02) ≈ 0.1414
        // (a plain amplitude average would read 0.1).
        for _ in 0..<2_400 { acc.add(mic: 0.0, sys: 0.0) }
        for _ in 0..<2_400 { acc.add(mic: 0.2, sys: 0.0) }
        guard let levels = acc.flush(sampleRate: 48_000) else {
            return XCTFail("0.1 s of frames must flush a level pair")
        }
        XCTAssertEqual(levels.mic, Float(0.02).squareRoot(), accuracy: 0.001)
        XCTAssertEqual(levels.system, 0, accuracy: 0.001)
    }
}

// Lives here rather than in MeetingRecorderCenterTests.swift only because that
// file sits at its swiftlint file_length cap; the extension keeps the test
// inside the `--filter MeetingRecorderCenterTests` run with its shared fixtures.
extension MeetingRecorderCenterTests {

    func testCaptureLevelsFollowRecorderAndResetOnStop() async throws {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 3)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["hello"])) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )

        await center.startRecording(eventID: nil, title: "Levels")
        XCTAssertEqual(center.captureLevels, CaptureLevels(mic: 0, system: 0),
                       "levels start at zero until the recorder reports a window")

        recorder.emitLevels(CaptureLevels(mic: 0.1, system: 0.3))
        await waitUntil("levels reach the center") {
            center.captureLevels == CaptureLevels(mic: 0.1, system: 0.3)
        }

        await center.stopAndProcess(config: singleWindowConfig())
        await waitUntil("levels reset on stop") {
            center.captureLevels == CaptureLevels(mic: 0, system: 0)
        }
    }
}
