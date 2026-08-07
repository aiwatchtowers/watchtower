import XCTest
@testable import WatchtowerDesktop

/// Scripted engine: canned per-window detection results + transcription texts.
/// Records every forced language, window size and context prompt passed in.
private final class MockEngine: WhisperWindowEngine, @unchecked Sendable {
    enum Detection {
        case probs([String: Float])
        case failure
    }

    struct MockError: Error {}

    var detections: [Detection] = []
    var texts: [Result<String, Error>] = []

    private(set) var detectCallCount = 0
    private(set) var transcribedLanguages: [String] = []
    private(set) var windowSizes: [Int] = []
    private(set) var prompts: [String?] = []

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] {
        let idx = detectCallCount
        detectCallCount += 1
        guard idx < detections.count else { throw MockError() }
        switch detections[idx] {
        case .probs(let probs): return probs
        case .failure: throw MockError()
        }
    }

    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
        windowSizes.append(samples.count)
        transcribedLanguages.append(language)
        prompts.append(prompt)
        let idx = transcribedLanguages.count - 1
        let text = idx < texts.count ? try texts[idx].get() : ""
        return [TranscribedSegment(text: text, startSec: 0,
                                   endSec: Double(samples.count) / Double(TranscriptionConfig.sampleRate))]
    }
}

/// Thread-safe recorder for the @Sendable progress callback.
private final class ProgressRecorder: @unchecked Sendable {
    private(set) var calls: [(index: Int, count: Int)] = []
    func record(_ index: Int, _ count: Int) {
        calls.append((index, count))
    }
}

final class WindowedTranscriberTests: XCTestCase {

    /// Small windows so test sample arrays stay tiny: 0.01 s = 160 samples, no overlap.
    private func tinyConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.windowSec = 0.01
        config.overlapSec = 0
        config.boundarySnapSec = 0 // exact window sizes are asserted below
        return config
    }

    /// Samples spanning exactly `windows` full windows under `config` (requires overlapSec == 0).
    private func samples(windows: Int, config: TranscriptionConfig) -> [Float] {
        let windowSamples = Int(config.windowSec * Double(TranscriptionConfig.sampleRate))
        return [Float](repeating: 0, count: windows * windowSamples)
    }

    private func run(_ engine: MockEngine,
                     _ config: TranscriptionConfig,
                     windows: Int,
                     progress: ProgressRecorder = ProgressRecorder()) async throws -> TranscriptionOutput {
        let transcriber = WindowedTranscriber(engine: engine, config: config)
        return try await transcriber.transcribe(samples: samples(windows: windows, config: config)) {
            progress.record($0, $1)
        }
    }

    // MARK: - Language selection

    func testForcedLanguageSkipsDetection() async throws {
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("hello")]

        let output = try await run(engine, config, windows: 1)

        XCTAssertEqual(engine.detectCallCount, 0)
        XCTAssertEqual(engine.transcribedLanguages, ["en"])
        XCTAssertEqual(output.text, "hello")
        XCTAssertEqual(output.langStats, ["en": 1])
    }

    func testConfidentDetectionUsed() async throws {
        let engine = MockEngine()
        engine.detections = [.probs(["ru": 0.9, "en": 0.05])]
        engine.texts = [.success("привет")]

        let output = try await run(engine, tinyConfig(), windows: 1)

        XCTAssertEqual(engine.transcribedLanguages, ["ru"])
        XCTAssertEqual(output.text, "привет")
        XCTAssertEqual(output.langStats, ["ru": 1])
    }

    func testLowConfidenceFallsBackToPrevious() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["ru": 0.9, "en": 0.05]),
            .probs(["ru": 0.4, "en": 0.35])
        ]
        engine.texts = [.success("раз"), .success("два")]

        let output = try await run(engine, tinyConfig(), windows: 2)

        XCTAssertEqual(engine.transcribedLanguages, ["ru", "ru"])
        XCTAssertEqual(output.langStats, ["ru": 2])
    }

    func testLowMarginFallsBackToPrevious() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["ru": 0.9, "en": 0.05]),
            .probs(["ru": 0.62, "uk": 0.55]) // margin 0.07 < 0.2
        ]
        engine.texts = [.success("раз"), .success("два")]

        let output = try await run(engine, tinyConfig(), windows: 2)

        XCTAssertEqual(engine.transcribedLanguages, ["ru", "ru"])
        XCTAssertEqual(output.langStats, ["ru": 2])
    }

    func testFirstWindowLowConfidenceUsesDefault() async throws {
        let engine = MockEngine()
        engine.detections = [.probs(["ru": 0.4, "en": 0.35])]
        engine.texts = [.success("что-то")]

        _ = try await run(engine, tinyConfig(), windows: 1)

        XCTAssertEqual(engine.transcribedLanguages, ["ru"])
    }

    func testSilentWindowDoesNotStick() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["en": 0.9, "ru": 0.02]),
            .probs(["uk": 0.9, "ru": 0.02]),
            .probs(["ru": 0.3, "en": 0.3]) // unsure → fallback
        ]
        engine.texts = [.success("hello"), .success(""), .success("again")]

        let output = try await run(engine, tinyConfig(), windows: 3)

        // w2 detected uk but produced no speech, so w3 falls back to en (not uk).
        XCTAssertEqual(engine.transcribedLanguages, ["en", "uk", "en"])
        XCTAssertEqual(output.text, "hello\nagain")
        XCTAssertEqual(output.langStats, ["en": 2])
    }

    func testLangsetRestriction() async throws {
        let engine = MockEngine()
        // Best overall is "de", but restricted to langset {ru,uk,en} the best is
        // ru@0.04 which is below threshold → first-window default "ru".
        engine.detections = [.probs(["de": 0.95, "ru": 0.04, "en": 0.01])]
        engine.texts = [.success("текст")]

        _ = try await run(engine, tinyConfig(), windows: 1)

        XCTAssertEqual(engine.transcribedLanguages, ["ru"])
    }

    // MARK: - Context prompt

    func testPromptCarriesPreviousWindowText() async throws {
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("one"), .success("two"), .success("three")]

        _ = try await run(engine, config, windows: 3)

        XCTAssertEqual(engine.prompts, [nil, "one", "two"])
    }

    func testSilentWindowKeepsPreviousPrompt() async throws {
        // Context survives a non-speech window, mirroring sticky language.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("one"), .success(""), .success("three")]

        _ = try await run(engine, config, windows: 3)

        XCTAssertEqual(engine.prompts, [nil, "one", "one"])
    }

    func testLanguageFlipDropsPrompt() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["en": 0.9, "ru": 0.02]),
            .probs(["uk": 0.9, "ru": 0.02])
        ]
        engine.texts = [.success("hello"), .success("привіт")]

        _ = try await run(engine, tinyConfig(), windows: 2)

        XCTAssertEqual(engine.transcribedLanguages, ["en", "uk"])
        XCTAssertEqual(engine.prompts, [nil, nil], "a ru/en prompt must never condition another language")
    }

    func testDisabledContextPromptNeverPrompts() async throws {
        var config = tinyConfig()
        config.forcedLanguage = "en"
        config.contextPrompt = false
        let engine = MockEngine()
        engine.texts = [.success("one"), .success("two"), .success("three")]

        let output = try await run(engine, config, windows: 3)

        XCTAssertEqual(engine.prompts, [nil, nil, nil])
        XCTAssertEqual(output.text, "one\ntwo\nthree")
    }

    func testFailedWindowKeepsPreviousPrompt() async throws {
        // A window that throws leaves the context untouched: with the engine's
        // retry-on-throw, an error here means the CLEAN decode failed, so the
        // prompt is not implicated and the next window still gets it.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("one"), .failure(MockEngine.MockError()), .success("three")]

        _ = try await run(engine, config, windows: 3)

        XCTAssertEqual(engine.prompts, [nil, "one", "one"])
    }

    func testPromptExpiresAfterThreeSilentWindows() async throws {
        // Two silent windows still prompt; the third clears the context so a
        // long pause cannot condition distant speech (and stops paying the
        // prompt+retry tax on every window of that pause).
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [
            .success("one"),
            .success(""), .success(""), .success(""),
            .success("after the pause")
        ]

        _ = try await run(engine, config, windows: 5)

        XCTAssertEqual(engine.prompts, [nil, "one", "one", "one", nil])
    }

    func testPromptIsCappedAtTwoHundredCharacters() async throws {
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        let long = String(repeating: "x", count: 150) + String(repeating: "y", count: 150)
        engine.texts = [.success(long), .success("next")]

        _ = try await run(engine, config, windows: 2)

        let tail = String(repeating: "x", count: 50) + String(repeating: "y", count: 150)
        XCTAssertEqual(engine.prompts, [nil, tail])
    }

    // MARK: - Errors

    func testDetectErrorFallsBack() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["ru": 0.9, "en": 0.05]),
            .failure
        ]
        engine.texts = [.success("раз"), .success("два")]

        let output = try await run(engine, tinyConfig(), windows: 2)

        XCTAssertEqual(engine.transcribedLanguages, ["ru", "ru"])
        XCTAssertEqual(output.text, "раз\nдва")
        XCTAssertEqual(output.langStats, ["ru": 2])
    }

    func testAllWindowsFailThrowsEngineError() async throws {
        // Total engine failure: no text, no speech window → the last engine
        // error surfaces instead of an empty "no speech" output.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.failure(MockEngine.MockError()), .failure(MockEngine.MockError())]

        do {
            _ = try await run(engine, config, windows: 2)
            XCTFail("expected total engine failure to throw")
        } catch is MockEngine.MockError {
            // expected
        }
    }

    func testSilenceMixedWithErrorsThrows() async throws {
        // No window produced speech and one window failed → still a failure.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success(""), .failure(MockEngine.MockError()), .success("   ")]

        do {
            _ = try await run(engine, config, windows: 3)
            XCTFail("expected throw when errors occurred and no speech was produced")
        } catch is MockEngine.MockError {
            // expected
        }
    }

    func testAllSilenceWithoutErrorsReturnsEmptyOutput() async throws {
        // Genuine all-silence (no engine errors) still returns empty output.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success(""), .success("  \n")]

        let output = try await run(engine, config, windows: 2)

        XCTAssertEqual(output, TranscriptionOutput(text: "", langStats: [:]))
    }

    func testTranscribeErrorSkipsWindow() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["en": 0.9, "ru": 0.02]),
            .probs(["uk": 0.9, "ru": 0.02]),
            .probs(["ru": 0.3, "en": 0.3]) // unsure → fallback
        ]
        engine.texts = [.success("hello"), .failure(MockEngine.MockError()), .success("again")]

        let output = try await run(engine, tinyConfig(), windows: 3)

        // w2 errored: not counted, language does not stick → w3 falls back to en.
        XCTAssertEqual(engine.transcribedLanguages, ["en", "uk", "en"])
        XCTAssertEqual(output.text, "hello\nagain")
        XCTAssertEqual(output.langStats, ["en": 2])
    }

    // MARK: - Stats / windowing

    func testLangStatsCountsSpeechWindowsOnly() async throws {
        let engine = MockEngine()
        engine.detections = [
            .probs(["ru": 0.9, "en": 0.02]),
            .probs(["ru": 0.9, "en": 0.02]),
            .probs(["ru": 0.9, "en": 0.02])
        ]
        engine.texts = [.success("а"), .success("   \n"), .success("б")]

        let output = try await run(engine, tinyConfig(), windows: 3)

        XCTAssertEqual(output.langStats, ["ru": 2])
        XCTAssertEqual(output.text, "а\nб")
    }

    func testWindowingMath() async throws {
        // Defaults: 20 s window, 1 s overlap → step 19 s. 50 s of audio →
        // window starts at 0 s, 19 s, 38 s (3 windows), last one truncated to 12 s.
        var config = TranscriptionConfig()
        config.boundarySnapSec = 0 // exact nominal boundaries are asserted
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("a"), .success("b"), .success("c")]
        let recorder = ProgressRecorder()
        let transcriber = WindowedTranscriber(engine: engine, config: config)
        let audio = [Float](repeating: 0, count: 50 * TranscriptionConfig.sampleRate)

        let output = try await transcriber.transcribe(samples: audio) { recorder.record($0, $1) }

        XCTAssertEqual(engine.windowSizes, [320_000, 320_000, 192_000])
        XCTAssertEqual(recorder.calls.count, 3)
        XCTAssertEqual(recorder.calls.map(\.index), [1, 2, 3])
        XCTAssertEqual(recorder.calls.map(\.count), [3, 3, 3])
        XCTAssertEqual(output.text, "a\nb\nc")
    }

    func testExactWindowLengthIsSingleWindow() async throws {
        // Recording length == window length: a tail start at `step` would lie
        // entirely inside the first window's overlap and only duplicate its
        // audio and lang stats — it must not be emitted.
        var config = TranscriptionConfig() // 20 s window, 1 s overlap
        config.boundarySnapSec = 0
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("only"), .success("dup")]
        let recorder = ProgressRecorder()
        let transcriber = WindowedTranscriber(engine: engine, config: config)
        let audio = [Float](repeating: 0, count: 20 * TranscriptionConfig.sampleRate)

        let output = try await transcriber.transcribe(samples: audio) { recorder.record($0, $1) }

        XCTAssertEqual(engine.windowSizes, [320_000])
        XCTAssertEqual(recorder.calls.map(\.index), [1])
        XCTAssertEqual(recorder.calls.map(\.count), [1])
        XCTAssertEqual(output.text, "only")
        XCTAssertEqual(output.langStats, ["en": 1])
    }

    func testJustOverWindowLengthIsTwoWindows() async throws {
        // 20.5 s: the second window extends past the first one's end → emitted.
        var config = TranscriptionConfig() // 20 s window, 1 s overlap
        config.boundarySnapSec = 0
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("a"), .success("b")]
        let transcriber = WindowedTranscriber(engine: engine, config: config)
        let audio = [Float](repeating: 0, count: Int(20.5 * Double(TranscriptionConfig.sampleRate)))

        let output = try await transcriber.transcribe(samples: audio) { _, _ in }

        XCTAssertEqual(engine.windowSizes, [320_000, 24_000])
        XCTAssertEqual(output.text, "a\nb")
    }

    func testSegmentsCarryAbsoluteTimestamps() async throws {
        // tinyConfig: 0.01 s windows (160 samples), snap off. The mock returns
        // one segment per window spanning [0, windowDur) → absolute offsets
        // must shift by k·0.01 s.
        var config = tinyConfig()
        config.forcedLanguage = "en"
        let engine = MockEngine()
        engine.texts = [.success("a"), .success("b")]

        let output = try await run(engine, config, windows: 2)

        XCTAssertEqual(output.segments.map(\.text), ["a", "b"])
        XCTAssertEqual(output.segments.map(\.language), ["en", "en"])
        XCTAssertEqual(output.segments[0].startSec, 0.0, accuracy: 1e-9)
        XCTAssertEqual(output.segments[1].startSec, 0.01, accuracy: 1e-9)
        XCTAssertEqual(output.segments[1].endSec, 0.02, accuracy: 1e-9)
    }

    func testEmptySamplesReturnsEmptyOutput() async throws {
        let engine = MockEngine()
        let recorder = ProgressRecorder()
        let transcriber = WindowedTranscriber(engine: engine, config: tinyConfig())

        let output = try await transcriber.transcribe(samples: []) { recorder.record($0, $1) }

        XCTAssertEqual(output, TranscriptionOutput(text: "", langStats: [:]))
        XCTAssertEqual(engine.detectCallCount, 0)
        XCTAssertTrue(engine.transcribedLanguages.isEmpty)
        XCTAssertTrue(recorder.calls.isEmpty)
    }
}
