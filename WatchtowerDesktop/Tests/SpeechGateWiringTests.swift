import XCTest
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Board #564: the gate wiring inside the real transcriber types — the
/// production `SpeechDetectorSlot` (Silero, created lazily), the kill switch
/// (`transcription.speechGate` off) bypassing it, and Qwen3's detector
/// reaching its windower on both the batch and the live path. Decoding is
/// faked (no ASR model); the one test that needs the Silero model skips when
/// it is not on disk, so the suite never downloads it.
final class SpeechGateWiringTests: XCTestCase {
    private let rate = TranscriptionConfig.sampleRate

    private func gateOff() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.speechGate = false
        return config
    }

    /// A detector the kill switch must never reach.
    private final class ForbiddenDetector: SpeechDetector, @unchecked Sendable {
        func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
            XCTFail("the gate is off: the detector must not be asked")
            return []
        }
    }

    private final class DecodeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var inputs: [[Float]] = []
        var decoded: [[Float]] { lock.withLock { inputs } }
        func record(_ samples: [Float]) { lock.withLock { inputs.append(samples) } }
    }

    // MARK: SpeechDetectorSlot

    func testSlotCreatesOneSileroDetectorOnlyWithTheGateOn() throws {
        let slot = SpeechDetectorSlot()
        XCTAssertNil(slot.detector(for: gateOff()), "the kill switch creates no detector")
        let first = try XCTUnwrap(slot.detector(for: TranscriptionConfig()))
        XCTAssertTrue(first is SileroSpeechDetector, "production detects with Silero")
        let second = try XCTUnwrap(slot.detector(for: TranscriptionConfig()))
        XCTAssertTrue((first as AnyObject) === (second as AnyObject), "one detector per transcriber")
        XCTAssertNil(slot.detector(for: gateOff()), "a created detector is still not handed out with the gate off")
    }

    func testSlotWithAnInjectedDetectorHonoursTheKillSwitch() {
        let slot = SpeechDetectorSlot(detector: ForbiddenDetector())
        XCTAssertNil(slot.detector(for: gateOff()))
        XCTAssertTrue(slot.detector(for: TranscriptionConfig()) is ForbiddenDetector)
    }

    // MARK: Whole-buffer engines, production slot

    func testGateOffDecodesTheRawBufferWithTheProductionSlot() async throws {
        let samples = [Float](repeating: 0, count: 2 * rate)
        let log = DecodeLog()
        _ = try await ParakeetTranscriber { log.record($0); return "a" }
            .transcribe(samples, config: gateOff()) { _, _ in }
        _ = try await AppleTranscriber { audio, _ in
            XCTAssertNil(audio.speech, "nothing to mute with the gate off")
            log.record(audio.muted())
            return "b"
        }.transcribe(samples, config: gateOff()) { _, _ in }
        XCTAssertEqual(log.decoded, [samples, samples], "silence is decoded as before the gate")
    }

    /// The Silero model FluidAudio keeps under Application Support, found by
    /// name prefix so a FluidAudio bump to a new model version does not turn
    /// the test into a permanent skip.
    private func sileroModelOnDisk() -> URL? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/silero-vad")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { $0.hasPrefix("silero-vad") && $0.hasSuffix(".mlmodelc") }
            .map { folder.appendingPathComponent($0) }
    }

    func testRealSileroGatesNoiseTheEnergyFallbackWouldOpen() async throws {
        try XCTSkipUnless(sileroModelOnDisk() != nil,
                          "Silero VAD model not on disk; the suite never downloads it")
        // 40 s: digital silence with 2 s of loud white noise. The energy
        // fallback calls the noise speech; Silero does not. So the recording
        // goes undecoded only if the real model decided it.
        var samples = [Float](repeating: 0, count: 40 * rate)
        samples.replaceSubrange((10 * rate)..<(12 * rate),
                                with: SyntheticAudio.whiteNoise(seconds: 2, dBFS: -20, seed: 7))
        XCTAssertFalse(SpeechGate.isSilent(EnergySpeechDetector().speechRanges(in: Array(samples[0..<(30 * rate)])),
                                           sampleRate: rate), "precondition: energy would open the noise")

        let detector = SileroSpeechDetector()
        let ranges = try await detector.speechRanges(in: Array(samples[0..<(30 * rate)]))
        XCTAssertTrue(SpeechGate.isSilent(ranges, sampleRate: rate), "the real model finds no speech in noise")

        let log = DecodeLog()
        let output = try await ParakeetTranscriber(speechDetector: detector) { log.record($0); return "Thanks." }
            .transcribe(samples, config: TranscriptionConfig()) { _, _ in }
        XCTAssertTrue(log.decoded.isEmpty, "Silero, not the energy fallback, gated the recording")
        XCTAssertEqual(output.text, "")
    }

    // MARK: SileroSpeechDetector's model load (no model)

    /// A segmenter load the test finishes by hand.
    private final class ManualSegmenterLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<SileroSpeechDetector.Segmenter, Error>?
        var started: Bool { lock.withLock { pending != nil } }
        func run() async throws -> SileroSpeechDetector.Segmenter {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending = continuation }
            }
        }
        func finish(_ segmenter: @escaping SileroSpeechDetector.Segmenter) async {
            while !started { await Task.yield() }
            lock.withLock { pending }?.resume(returning: segmenter)
        }
    }

    private func silero(_ load: ManualSegmenterLoad) -> SileroSpeechDetector {
        SileroSpeechDetector(model: BackgroundLoad(onUnobservedFailure: { _ in }, { try await load.run() }))
    }

    func testSileroIsNotReadyUntilItsModelLoadsThenUsesIt() async throws {
        let load = ManualSegmenterLoad()
        let detector = silero(load)
        do {
            _ = try await detector.speechRanges(in: [0.1, 0.2], modelWait: .zero)
            XCTFail("no model yet")
        } catch {
            XCTAssertTrue(error is SpeechDetectorNotReady, "got \(error)")
        }
        await load.finish { samples in [0..<samples.count] }
        let ranges = try await detector.speechRanges(in: [0.1, 0.2, 0.3], modelWait: nil)
        XCTAssertEqual(ranges, [0..<3], "once loaded, the window goes to the model")
    }

    func testCancelWhileTheModelLoadsEndsTheWaitWithoutAFailure() async throws {
        let load = ManualSegmenterLoad()
        let detector = silero(load)
        let window = [Float](repeating: 0.3, count: rate)
        let started = ContinuousClock.now
        let run = Task { () -> (WindowSpeech, String?) in
            var gate = WindowSpeechGate(detector: detector, config: TranscriptionConfig(),
                                        modelWait: WindowSpeechGate.batchModelWait)
            let verdict = await gate.check(window)
            return (verdict, gate.summary())
        }
        while !load.started { await Task.yield() }
        run.cancel()
        let (verdict, summary) = await run.value
        XCTAssertEqual(verdict, .silent, "a cancelled window is not decoded")
        XCTAssertNil(summary, "not counted as a fallback or a failure")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(60), "the cancel, not the 120 s wait, ended it")

        await load.finish { _ in [] }
        let ranges = try await detector.speechRanges(in: window, modelWait: nil)
        XCTAssertEqual(ranges, [], "the shared load went on")
    }

    // MARK: Qwen3

    /// 1 s windows, no overlap or snapping.
    private func windows() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.windowSec = 1
        config.overlapSec = 0
        config.boundarySnapSec = 0
        return config
    }

    /// Speech (non-zero) in seconds 0 and 2, digital silence in second 1.
    private func speechSilenceSpeech() -> [Float] {
        (0..<3).flatMap { second -> [Float] in
            [Float](repeating: second == 1 ? 0 : 0.3, count: rate)
        }
    }

    private func stream(_ samples: [Float]) -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            continuation.yield(samples)
            continuation.finish()
        }
    }

    func testQwen3DetectorReachesBatchAndLive() async throws {
        let log = DecodeLog()
        let transcriber = Qwen3Transcriber(speechDetector: FakeSpeechDetector()) { window, language in
            XCTAssertNil(language)
            log.record(window)
            return "spoken"
        }
        let batch = try await transcriber.transcribe(speechSilenceSpeech(), config: windows()) { _, _ in }
        XCTAssertEqual(log.decoded.count, 2, "batch: the silent window is never decoded")
        XCTAssertEqual(batch.text, "spoken\nspoken")

        let live = try XCTUnwrap(transcriber.makeLiveSession(config: windows()))
        let liveOutput = try await live.run(samples: stream(speechSilenceSpeech())) { _ in }
        XCTAssertEqual(log.decoded.count, 4, "live: the same gate")
        XCTAssertEqual(liveOutput.text, batch.text)
    }

    func testQwen3GateOffBypassesTheDetector() async throws {
        let log = DecodeLog()
        var config = windows()
        config.speechGate = false
        config.forcedLanguage = "en"
        let transcriber = Qwen3Transcriber(speechDetector: ForbiddenDetector()) { window, language in
            XCTAssertEqual(language, "en", "the forced language reaches the decode")
            log.record(window)
            return "w"
        }
        _ = try await transcriber.transcribe(speechSilenceSpeech(), config: config) { _, _ in }
        _ = try await XCTUnwrap(transcriber.makeLiveSession(config: config))
            .run(samples: stream(speechSilenceSpeech())) { _ in }
        XCTAssertEqual(log.decoded.count, 6, "every window decoded on both paths")
    }
}
