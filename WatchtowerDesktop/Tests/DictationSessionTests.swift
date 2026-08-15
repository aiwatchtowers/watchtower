import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `WhisperDictationSession` — the whisper pseudo-streaming lane behind the
/// `DictationTranscribing` seam (realtime-dictation spec §2). Drives the REAL
/// provider live machinery (`StreamingTranscriber` via `TestTranscriber`)
/// with a scripted window engine.
@MainActor
final class DictationSessionTests: XCTestCase {

    /// Forced language (detection never consulted) + the meeting-sized 10 s
    /// window so one 240_000-sample (15 s) chunk fully covers a window's snap
    /// zone and decodes immediately.
    private func makeConfig() -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.windowSec = 10
        config.diarization = false
        return config
    }

    func testAccumulatesFullTextUpdatesAndReturnsFinalText() async throws {
        let session = WhisperDictationSession(
            transcriber: TestTranscriber(ScriptedEngine(texts: ["hello", "world"]), supportsLive: true),
            config: makeConfig()
        )
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        continuation.yield([Float](repeating: 0.1, count: 240_000))
        continuation.yield([Float](repeating: 0.1, count: 240_000))
        continuation.finish()

        var updates: [String] = []
        let final = try await session.run(samples: stream) { updates.append($0) }

        // The per-chunk updates hop through main-actor tasks — drain them.
        for _ in 0..<400 where updates.count < 2 { await Task.yield() }

        XCTAssertEqual(final, "hello\nworld", "the live output's final text must be returned as-is")
        XCTAssertEqual(updates, ["hello", "hello world"],
                       "each chunk must fire the FULL accumulated string, not the delta")
    }

    func testBatchOnlyTranscriberThrowsLiveUnsupported() async {
        let session = WhisperDictationSession(
            transcriber: TestTranscriber(ScriptedEngine(texts: ["never delivered"]), supportsLive: false),
            config: makeConfig()
        )
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        continuation.finish()

        do {
            _ = try await session.run(samples: stream) { _ in
                XCTFail("a batch-only transcriber must never fire updates")
            }
            XCTFail("a batch-only transcriber must throw .liveUnsupported")
        } catch DictationSessionError.liveUnsupported {
            // Expected: the center answers with its buffer batch decode.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
