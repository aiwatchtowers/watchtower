import XCTest
@testable import WatchtowerDesktop

/// Records forced languages, window sizes + context prompts; returns canned
/// texts in call order.
private final class MockEngine: WhisperWindowEngine, @unchecked Sendable {
    var texts: [Result<String, Error>] = []
    var detections: [[String: Float]] = []
    struct MockError: Error {}
    private(set) var transcribedLanguages: [String] = []
    private(set) var windowSizes: [Int] = []
    private(set) var prompts: [String?] = []
    private var detectIdx = 0

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] {
        defer { detectIdx += 1 }
        return detectIdx < detections.count ? detections[detectIdx] : [:]
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

private final class ChunkSink: @unchecked Sendable {
    private(set) var chunks: [StreamChunk] = []
    func record(_ c: StreamChunk) { chunks.append(c) }
}

final class StreamingTranscriberTests: XCTestCase {

    private func forcedConfig(windowSec: Double = 0.1, overlapSec: Double = 0) -> TranscriptionConfig {
        var c = TranscriptionConfig()
        c.windowSec = windowSec
        c.overlapSec = overlapSec
        c.boundarySnapSec = 0 // exact window sizes are asserted; snapping is pinned separately
        c.forcedLanguage = "en"
        return c
    }

    /// Pushes `samples` into a fresh AsyncStream in `pieceSize`-sample pieces, then finishes.
    private func stream(of samples: [Float], pieceSize: Int) -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            var i = 0
            while i < samples.count {
                let end = min(i + pieceSize, samples.count)
                continuation.yield(Array(samples[i..<end]))
                i = end
            }
            continuation.finish()
        }
    }

    // 0.1 s window @ 16 kHz = 1600 samples.
    func testThreeFullWindowsPlusTail() async throws {
        let engine = MockEngine()
        engine.texts = [.success("a"), .success("b"), .success("c")]
        let sink = ChunkSink()
        let transcriber = StreamingTranscriber(engine: engine, config: forcedConfig())
        // 3.5 windows = 5600 samples, pushed in ragged 700-sample pieces.
        let output = try await transcriber.run(samples: stream(of: [Float](repeating: 0, count: 5600), pieceSize: 700)) {
            sink.record($0)
        }
        XCTAssertEqual(engine.windowSizes, [1600, 1600, 1600, 800]) // 3 full + 800 tail
        XCTAssertEqual(output.text, "a\nb\nc") // 4th window past texts → ""
        XCTAssertEqual(output.langStats, ["en": 3])
        XCTAssertEqual(sink.chunks.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(sink.chunks.map(\.index), [1, 2, 3])
    }

    func testMatchesBatchOnSameSamples() async throws {
        // Equivalence with WindowedTranscriber: same samples, same scripting → same output.
        let samples = [Float](repeating: 0, count: 5600)
        let cfg = forcedConfig()

        let batchEngine = MockEngine()
        batchEngine.texts = [.success("a"), .success("b"), .success("c"), .success("d")]
        let batchOut = try await WindowedTranscriber(engine: batchEngine, config: cfg)
            .transcribe(samples: samples) { _, _ in }

        let streamEngine = MockEngine()
        streamEngine.texts = [.success("a"), .success("b"), .success("c"), .success("d")]
        let streamOut = try await StreamingTranscriber(engine: streamEngine, config: cfg)
            .run(samples: stream(of: samples, pieceSize: 333)) { _ in }

        XCTAssertEqual(streamOut, batchOut)
        XCTAssertEqual(streamEngine.windowSizes, batchEngine.windowSizes)
        XCTAssertEqual(streamEngine.prompts, batchEngine.prompts)
    }

    func testMatchesBatchWithOverlap() async throws {
        // Same equivalence check as `testMatchesBatchOnSameSamples`, but with a
        // non-zero overlap — production `TranscriptionConfig` defaults to
        // `overlapSec: 1.0`, so `step < windowSamples` (the overlapping-window
        // path) must be pinned too, not just the `overlapSec: 0` case.
        //
        // 0.1 s window / 0.05 s overlap @ 16 kHz → windowSamples 1600, step 800.
        // 4500 samples yields starts [0, 800, 1600, 2400, 3200]: four full
        // 1600-sample windows plus a truncated 1300-sample tail.
        let samples = [Float](repeating: 0, count: 4500)
        let cfg = forcedConfig(windowSec: 0.1, overlapSec: 0.05)

        let batchEngine = MockEngine()
        batchEngine.texts = [.success("a"), .success("b"), .success("c"), .success("d"), .success("e")]
        let batchOut = try await WindowedTranscriber(engine: batchEngine, config: cfg)
            .transcribe(samples: samples) { _, _ in }

        let streamEngine = MockEngine()
        streamEngine.texts = [.success("a"), .success("b"), .success("c"), .success("d"), .success("e")]
        let streamOut = try await StreamingTranscriber(engine: streamEngine, config: cfg)
            .run(samples: stream(of: samples, pieceSize: 333)) { _ in }

        XCTAssertEqual(streamOut, batchOut)
        XCTAssertEqual(streamEngine.windowSizes, batchEngine.windowSizes)
        XCTAssertEqual(streamEngine.prompts, batchEngine.prompts)
        XCTAssertEqual(batchEngine.windowSizes, [1600, 1600, 1600, 1600, 1300],
                       "sanity check: four overlapping full windows plus a truncated tail")
    }

    func testMatchesBatchWithSnappingOnSameSamples() async throws {
        // The snapping path must cut IDENTICAL windows live and batch. Loud
        // signal with quiet dips at irregular offsets so cuts land off the
        // nominal boundaries (and the post-close tail holds several windows).
        var samples = [Float](repeating: 0.5, count: 8000)
        for dip in [1650..<2050, 3100..<3400, 4700..<5000] {
            for i in dip { samples[i] = 0.0 }
        }
        var cfg = forcedConfig() // windowSec 0.1, overlap 0
        cfg.boundarySnapSec = 0.02

        let batchEngine = MockEngine()
        batchEngine.texts = (0..<8).map { .success("w\($0)") }
        let batchOut = try await WindowedTranscriber(engine: batchEngine, config: cfg)
            .transcribe(samples: samples) { _, _ in }

        let streamEngine = MockEngine()
        streamEngine.texts = (0..<8).map { .success("w\($0)") }
        let streamOut = try await StreamingTranscriber(engine: streamEngine, config: cfg)
            .run(samples: stream(of: samples, pieceSize: 271)) { _ in }

        XCTAssertEqual(streamOut, batchOut)
        XCTAssertEqual(streamEngine.windowSizes, batchEngine.windowSizes)
        XCTAssertEqual(streamEngine.prompts, batchEngine.prompts)
        XCTAssertNotEqual(batchEngine.windowSizes.first, 1600,
                          "sanity: snapping actually moved the first boundary")
    }

    func testExactWindowLengthIsSingleWindow() async throws {
        // Recording length == window length → one window, no duplicate tail (batch parity).
        let engine = MockEngine()
        engine.texts = [.success("only"), .success("dup")]
        let output = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 1600), pieceSize: 1600)) { _ in }
        XCTAssertEqual(engine.windowSizes, [1600])
        XCTAssertEqual(output.text, "only")
        XCTAssertEqual(output.langStats, ["en": 1])
    }

    func testDegenerateShortStreamIsOneTruncatedWindow() async throws {
        // Stream closes mid-window (fewer than windowSamples): the tail is the
        // single (truncated) window — a valid-but-degenerate input, not an error.
        let engine = MockEngine()
        engine.texts = [.success("hi")]
        let output = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 500), pieceSize: 120)) { _ in }
        XCTAssertEqual(engine.windowSizes, [500])
        XCTAssertEqual(output.text, "hi")
    }

    func testEmptyStreamReturnsEmpty() async throws {
        let engine = MockEngine()
        let sink = ChunkSink()
        let output = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: AsyncStream { $0.finish() }) { sink.record($0) }
        XCTAssertEqual(output, TranscriptionOutput(text: "", langStats: [:]))
        XCTAssertTrue(engine.windowSizes.isEmpty)
        XCTAssertTrue(sink.chunks.isEmpty)
    }

    func testTotalEngineFailureThrows() async throws {
        // No speech + an error → throw (never a silent empty), matching batch.
        let engine = MockEngine()
        engine.texts = [.failure(MockEngine.MockError()), .failure(MockEngine.MockError())]
        do {
            _ = try await StreamingTranscriber(engine: engine, config: forcedConfig())
                .run(samples: stream(of: [Float](repeating: 0, count: 3200), pieceSize: 3200)) { _ in }
            XCTFail("expected throw on total engine failure")
        } catch is MockEngine.MockError { /* expected */ }
    }

    func testFailedWindowSkippedLanguageDoesNotStick() async throws {
        // Detection-driven: w2 errors → not counted, language does not stick.
        var cfg = forcedConfig()
        cfg.forcedLanguage = nil
        let engine = MockEngine()
        engine.detections = [["en": 0.9, "ru": 0.02], ["uk": 0.9, "ru": 0.02], ["ru": 0.3, "en": 0.3]]
        engine.texts = [.success("hello"), .failure(MockEngine.MockError()), .success("again")]
        let output = try await StreamingTranscriber(engine: engine, config: cfg)
            .run(samples: stream(of: [Float](repeating: 0, count: 4800), pieceSize: 1000)) { _ in }
        XCTAssertEqual(engine.transcribedLanguages, ["en", "uk", "en"])
        XCTAssertEqual(output.text, "hello\nagain")
        XCTAssertEqual(output.langStats, ["en": 2])
    }

    // MARK: - Context prompt

    func testPromptCarriesPreviousWindowText() async throws {
        let engine = MockEngine()
        engine.texts = [.success("one"), .success("two"), .success("three")]
        _ = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 4800), pieceSize: 700)) { _ in }
        XCTAssertEqual(engine.prompts, [nil, "one", "two"])
    }

    func testSilentWindowKeepsPreviousPrompt() async throws {
        // Context survives a non-speech window, mirroring sticky language.
        let engine = MockEngine()
        engine.texts = [.success("one"), .success(""), .success("three")]
        _ = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 4800), pieceSize: 700)) { _ in }
        XCTAssertEqual(engine.prompts, [nil, "one", "one"])
    }

    func testLanguageFlipDropsPrompt() async throws {
        var cfg = forcedConfig()
        cfg.forcedLanguage = nil
        let engine = MockEngine()
        engine.detections = [["en": 0.9, "ru": 0.02], ["uk": 0.9, "ru": 0.02]]
        engine.texts = [.success("hello"), .success("привіт")]
        _ = try await StreamingTranscriber(engine: engine, config: cfg)
            .run(samples: stream(of: [Float](repeating: 0, count: 3200), pieceSize: 700)) { _ in }
        XCTAssertEqual(engine.transcribedLanguages, ["en", "uk"])
        XCTAssertEqual(engine.prompts, [nil, nil], "a ru/en prompt must never condition another language")
    }

    func testDisabledContextPromptNeverPrompts() async throws {
        var cfg = forcedConfig()
        cfg.contextPrompt = false
        let engine = MockEngine()
        engine.texts = [.success("one"), .success("two"), .success("three")]
        let output = try await StreamingTranscriber(engine: engine, config: cfg)
            .run(samples: stream(of: [Float](repeating: 0, count: 4800), pieceSize: 700)) { _ in }
        XCTAssertEqual(engine.prompts, [nil, nil, nil])
        XCTAssertEqual(output.text, "one\ntwo\nthree")
    }

    func testPromptIsCappedAtTwoHundredCharacters() async throws {
        let engine = MockEngine()
        let long = String(repeating: "x", count: 150) + String(repeating: "y", count: 150)
        engine.texts = [.success(long), .success("next")]
        _ = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 3200), pieceSize: 700)) { _ in }
        let tail = String(repeating: "x", count: 50) + String(repeating: "y", count: 150)
        XCTAssertEqual(engine.prompts, [nil, tail])
    }
}
