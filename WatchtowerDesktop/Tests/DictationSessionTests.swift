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

    /// The `MeetingRecorderTestCase.waitUntil` shape, local because this
    /// suite is not a subclass: yields the main actor until `condition`
    /// holds, failing instead of hanging.
    private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(what)")
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
        await waitUntil("both updates delivered") { updates.count >= 2 }

        XCTAssertEqual(final, "hello\nworld", "the live output's final text must be returned as-is")
        XCTAssertEqual(updates, ["hello", "hello world"],
                       "each chunk must fire the FULL accumulated string, not the delta")
    }

    // MARK: - Apple dictation locale (owner call 2026-08-16: the app's own
    // language settings decide — forceLang, else langset; never Locale.current)

    /// The resolver consumed by the dictation session factory
    /// (`DictationCenter.defaultSessionFactory`); the batch `AppleTranscriber`
    /// path keeps its langset resolution and is deliberately untouched.
    func testForcedLanguageWinsOverLangset() {
        XCTAssertEqual(
            AppleLocaleCatalog.resolveDictationLocale(forced: "en", langset: ["ru", "uk", "en"]),
            Locale(identifier: "en-US"))
    }

    /// The default langset "ru,uk,en": "ru" is the first Apple-supported entry,
    /// so dictation follows what the owner actually speaks — regardless of the
    /// machine's system locale (the 2026-08-16 live-repro bug: en_UA system
    /// locale reached SpeechTranscriber verbatim and killed the analyzer).
    func testNilForcedTakesFirstSupportedLangsetLanguage() {
        XCTAssertEqual(
            AppleLocaleCatalog.resolveDictationLocale(forced: nil, langset: ["ru", "uk", "en"]),
            Locale(identifier: "ru-RU"))
        // Apple ships no Ukrainian model — "uk" is skipped, not defaulted.
        XCTAssertEqual(
            AppleLocaleCatalog.resolveDictationLocale(forced: nil, langset: ["uk", "en"]),
            Locale(identifier: "en-US"))
    }

    func testUnsupportedForcedLanguageDegradesToLangset() {
        XCTAssertEqual(
            AppleLocaleCatalog.resolveDictationLocale(forced: "uk", langset: ["ru", "en"]),
            Locale(identifier: "ru-RU"))
    }

    func testNothingSupportedFallsToDefault() {
        XCTAssertEqual(
            AppleLocaleCatalog.resolveDictationLocale(forced: "uk", langset: ["uk"]),
            AppleLocaleCatalog.defaultLocale)
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
