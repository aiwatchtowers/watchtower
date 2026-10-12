import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// Returns scripted segments per decoded window (empty past the script) and
/// records every detection and decode.
private final class SegmentEngine: WhisperWindowEngine, @unchecked Sendable {
    struct EngineError: Error {}

    var script: [Result<[TranscribedSegment], Error>] = []
    /// Per detection call; confident en past the script.
    var detections: [[String: Float]] = []
    private(set) var detectCalls = 0
    private(set) var decodedWindowSizes: [Int] = []

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] {
        detectCalls += 1
        return detectCalls <= detections.count ? detections[detectCalls - 1] : ["en": 0.9]
    }

    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
        decodedWindowSizes.append(samples.count)
        let index = decodedWindowSizes.count - 1
        return index < script.count ? try script[index].get() : []
    }
}

private final class ProgressLog: @unchecked Sendable {
    private(set) var calls: [Int] = []
    func record(_ index: Int) { calls.append(index) }
}

final class SpeechGateTranscriberTests: XCTestCase {
    private let rate = TranscriptionConfig.sampleRate

    /// 1 s windows, no overlap or snapping, detection on.
    private func config() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.windowSec = 1
        config.overlapSec = 0
        config.boundarySnapSec = 0
        return config
    }

    /// One second per entry: the seconds (from the window start) holding speech, or nil for silence.
    private func audio(_ windows: [ClosedRange<Double>?]) -> [Float] {
        windows.flatMap { speech -> [Float] in
            var window = [Float](repeating: 0, count: rate)
            if let speech {
                for index in Int(speech.lowerBound * Double(rate))..<Int(speech.upperBound * Double(rate)) {
                    window[index] = index.isMultiple(of: 2) ? 0.3 : -0.3
                }
            }
            return window
        }
    }

    private func segment(_ text: String, _ start: Double, _ end: Double) -> TranscribedSegment {
        TranscribedSegment(text: text, startSec: start, endSec: end)
    }

    private func stream(_ samples: [Float], piece: Int = 4_000) -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            for start in stride(from: 0, to: samples.count, by: piece) {
                continuation.yield(Array(samples[start..<min(start + piece, samples.count)]))
            }
            continuation.finish()
        }
    }

    func testSilentWindowIsNeverDetectedOrDecodedButReportsProgress() async throws {
        let engine = SegmentEngine()
        engine.script = [.success([segment("one", 0, 1)]), .success([segment("three", 0, 1)])]
        let progress = ProgressLog()
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: FakeSpeechDetector())
            .transcribe(samples: audio([0.1...0.9, nil, 0.1...0.9])) { index, _ in progress.record(index) }

        XCTAssertEqual(engine.detectCalls, 2, "the silent window never reaches language detection")
        XCTAssertEqual(engine.decodedWindowSizes.count, 2, "nor the decoder")
        XCTAssertEqual(progress.calls, [1, 2, 3])
        XCTAssertEqual(output.text, "one\nthree")
        XCTAssertEqual(output.langStats, ["en": 2], "the silent window is not counted")
    }

    func testSilentWindowDoesNotStickItsLanguage() async throws {
        // Window 1 confident uk, window 2 silent, window 3 unconfident: it
        // falls back to window 1's uk — the silent window neither consumed a
        // detection nor reset the sticky language to the first-window default.
        let engine = SegmentEngine()
        engine.script = [.success([segment("one", 0, 1)]), .success([segment("three", 0, 1)])]
        engine.detections = [["uk": 0.9], ["ru": 0.4, "en": 0.35]]
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: FakeSpeechDetector())
            .transcribe(samples: audio([0.1...0.9, nil, 0.1...0.9])) { _, _ in }
        XCTAssertEqual(output.segments.map(\.language), ["uk", "uk"])
        XCTAssertEqual(output.langStats, ["uk": 2])
    }

    func testSegmentsOutsideSpeechAreDropped() async throws {
        let engine = SegmentEngine()
        // Speech 0.0–0.5 s; "thanks" sits in the silent half, "edge" overlaps 0.25 s.
        engine.script = [.success([segment("real", 0.0, 0.45), segment("thanks", 0.6, 0.95),
                                   segment("edge", 0.25, 0.9)])]
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: FakeSpeechDetector())
            .transcribe(samples: audio([0.0...0.5])) { _, _ in }
        XCTAssertEqual(output.text, "real edge")
    }

    func testWindowWithTooLittleSpeechIsSilent() async throws {
        let engine = SegmentEngine()
        engine.script = [.success([segment("blip", 0, 1)])]
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: FakeSpeechDetector())
            .transcribe(samples: audio([0.4...0.6])) { _, _ in }
        XCTAssertEqual(engine.decodedWindowSizes, [])
        XCTAssertEqual(output.text, "")
    }

    func testDetectorErrorFallsBackToEnergyAndStillDecodes() async throws {
        let engine = SegmentEngine()
        engine.script = [.success([segment("spoken", 0, 1)])]
        let detector = FakeSpeechDetector()
        detector.error = SegmentEngine.EngineError()
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: detector)
            .transcribe(samples: audio([0.1...0.6, nil])) { _, _ in }
        XCTAssertEqual(detector.calls, 1, "after the first error the recording stays on the fallback")
        XCTAssertEqual(engine.decodedWindowSizes, [rate], "the energy fallback opened the loud window only")
        XCTAssertEqual(output.text, "spoken")
    }

    func testCancellationIsNotADetectorFailure() async throws {
        // A cancelled detector call must not switch the recording to the
        // energy fallback (nor log a failure) and must not open the window.
        let engine = SegmentEngine()
        engine.script = [.success([segment("spoken", 0, 1)]), .success([segment("spoken", 0, 1)])]
        let detector = FakeSpeechDetector()
        detector.error = CancellationError()
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: detector)
            .transcribe(samples: audio([0.1...0.9, 0.1...0.9])) { _, _ in }
        XCTAssertEqual(detector.calls, 2, "no switch to the fallback: the detector is asked for every window")
        XCTAssertEqual(engine.decodedWindowSizes, [])
        XCTAssertEqual(output.text, "")
    }

    func testNextRecordingRetriesTheDetectorAfterAFailure() async throws {
        // The detector lives as long as the warm transcriber; a failure must
        // not pin later recordings to the fallback.
        let detector = FakeSpeechDetector()
        detector.error = SegmentEngine.EngineError()
        let samples = audio([0.1...0.6, nil, 0.2...0.8])
        _ = try await WindowedTranscriber(engine: SegmentEngine(), config: config(), speechDetector: detector)
            .transcribe(samples: samples) { _, _ in }
        XCTAssertEqual(detector.calls, 1, "recording 1: one failed call, then the fallback for every window")

        detector.error = nil
        _ = try await WindowedTranscriber(engine: SegmentEngine(), config: config(), speechDetector: detector)
            .transcribe(samples: samples) { _, _ in }
        XCTAssertEqual(detector.calls, 4, "recording 2 asks the detector again, for each of its 3 windows")

        detector.error = SegmentEngine.EngineError()
        _ = try await StreamingTranscriber(engine: SegmentEngine(), config: config(), speechDetector: detector)
            .run(samples: stream(samples)) { _ in }
        XCTAssertEqual(detector.calls, 5, "live follows the same per-recording switch")
    }

    func testAllSilentRecordingIsEmptyWithoutThrowing() async throws {
        let engine = SegmentEngine()
        let output = try await WindowedTranscriber(engine: engine, config: config(), speechDetector: FakeSpeechDetector())
            .transcribe(samples: audio([nil, nil, nil])) { _, _ in }
        XCTAssertEqual(output, TranscriptionOutput(text: "", langStats: [:]))
        XCTAssertEqual(engine.decodedWindowSizes, [])
    }

    func testAllWindowsFailingStillThrows() async {
        let engine = SegmentEngine()
        engine.script = [.failure(SegmentEngine.EngineError()), .failure(SegmentEngine.EngineError())]
        let transcriber = WindowedTranscriber(engine: engine, config: config(), speechDetector: FakeSpeechDetector())
        do {
            _ = try await transcriber.transcribe(samples: audio([0.1...0.9, nil, 0.1...0.9])) { _, _ in }
            XCTFail("total engine failure must throw, silent windows notwithstanding")
        } catch {
            XCTAssertTrue(error is SegmentEngine.EngineError)
        }
    }

    func testGateOffNeverCallsTheDetector() async throws {
        let script: [Result<[TranscribedSegment], Error>] = [
            .success([segment("a", 0, 1)]), .success([segment("b", 0.6, 0.9)])
        ]
        let detector = FakeSpeechDetector()
        var cfg = config()
        cfg.speechGate = false
        let batchEngine = SegmentEngine()
        batchEngine.script = script
        let batch = try await WindowedTranscriber(engine: batchEngine, config: cfg, speechDetector: detector)
            .transcribe(samples: audio([0.0...0.3, nil])) { _, _ in }
        let liveEngine = SegmentEngine()
        liveEngine.script = script
        let live = try await StreamingTranscriber(engine: liveEngine, config: cfg, speechDetector: detector)
            .run(samples: stream(audio([0.0...0.3, nil]))) { _ in }
        XCTAssertEqual(detector.calls, 0)
        XCTAssertEqual(batch.text, "a\nb", "both windows decode and keep every segment, as before the gate")
        XCTAssertEqual(live, batch)
    }

    func testLiveMatchesBatchWithTheGate() async throws {
        // speech, silent, speech with a segment in its gap, too little speech, speech.
        let samples = audio([0.0...0.9, nil, 0.0...0.4, 0.45...0.6, 0.2...1.0])
        let script: [Result<[TranscribedSegment], Error>] = [
            .success([segment("alpha", 0, 0.9)]),
            .success([segment("beta", 0, 0.4), segment("ghost", 0.6, 1.0)]),
            .success([segment("gamma", 0.1, 1.0)])
        ]
        var cfg = config()
        cfg.contextPrompt = true

        let batchEngine = SegmentEngine()
        batchEngine.script = script
        let batchDetector = FakeSpeechDetector()
        let batch = try await WindowedTranscriber(engine: batchEngine, config: cfg, speechDetector: batchDetector)
            .transcribe(samples: samples) { _, _ in }

        let liveEngine = SegmentEngine()
        liveEngine.script = script
        let liveDetector = FakeSpeechDetector()
        let live = try await StreamingTranscriber(engine: liveEngine, config: cfg, speechDetector: liveDetector)
            .run(samples: stream(samples, piece: 3_333)) { _ in }

        XCTAssertEqual(live, batch)
        XCTAssertEqual(liveEngine.decodedWindowSizes, batchEngine.decodedWindowSizes)
        XCTAssertEqual(liveDetector.calls, batchDetector.calls)
        XCTAssertEqual(batch.text, "alpha\nbeta\ngamma")
        XCTAssertEqual(batchEngine.decodedWindowSizes.count, 3)
    }

    func testDoubtfulSegmentDropFollowsTheGate() async throws {
        // L3 runs inside the engine; the transcribers hand it config.speechGate
        // per call, the same on both paths.
        final class FlagEngine: WhisperWindowEngine, @unchecked Sendable {
            var flags: [Bool] = []
            func detectLanguage(_ samples: [Float]) async throws -> [String: Float] { ["en": 0.9] }
            func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
                XCTFail("the transcribers must always pass the L3 flag")
                return []
            }
            func transcribeWindow(
                _ samples: [Float],
                language: String,
                prompt: String?,
                dropDoubtful: Bool
            ) async throws -> [TranscribedSegment] {
                flags.append(dropDoubtful)
                return [TranscribedSegment(text: "x", startSec: 0, endSec: 1)]
            }
        }
        let samples = audio([0.1...0.9, 0.1...0.9])
        for gate in [true, false] {
            var cfg = config()
            cfg.speechGate = gate
            let batch = FlagEngine()
            _ = try await WindowedTranscriber(engine: batch, config: cfg, speechDetector: FakeSpeechDetector())
                .transcribe(samples: samples) { _, _ in }
            let live = FlagEngine()
            _ = try await StreamingTranscriber(engine: live, config: cfg, speechDetector: FakeSpeechDetector())
                .run(samples: stream(samples)) { _ in }
            XCTAssertEqual(batch.flags, [gate, gate])
            XCTAssertEqual(live.flags, batch.flags)
        }
    }
}
