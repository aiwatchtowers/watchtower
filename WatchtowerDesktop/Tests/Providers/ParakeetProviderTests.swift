import XCTest
import FluidAudio
@testable import WatchtowerDesktop

final class ParakeetProviderTests: XCTestCase {
    func testMetadata() throws {
        let p = ParakeetProvider()
        XCTAssertEqual(type(of: p).id, "parakeet")
        XCTAssertFalse(p.supportsLive)
        if SystemInfo.isAppleSilicon {
            XCTAssertEqual(p.availability(), .available)
        } else {
            XCTAssertEqual(p.availability(), .unavailable(reason: "Requires Apple Silicon"))
        }
        let langs = p.supportedLanguages(model: "parakeet-tdt-0.6b-v3")
        XCTAssertNotNil(langs)
        XCTAssertTrue(try XCTUnwrap(langs).isSuperset(of: ["ru", "uk", "en"]))
    }

    func testRegistered() {
        XCTAssertTrue(TranscriptionProviderRegistry.all.contains { type(of: $0).id == "parakeet" })
    }

    /// Smoke test over a real FluidAudio model — only runs when the Parakeet v3
    /// CoreML bundle is already cached on disk (never triggers a download), so CI
    /// never depends on network/model availability.
    func testTranscribeShortSilenceWhenModelIsCached() async throws {
        try XCTSkipUnless(
            AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3),
            "Parakeet v3 model not cached locally; skipping smoke test"
        )

        let provider = ParakeetProvider()
        let transcriber = try await provider.makeTranscriber(model: "parakeet-tdt-0.6b-v3") { _ in }

        // 1 second of silence at 16 kHz — exercises the real transcribe path
        // without asserting on specific text (silence may yield empty output).
        let samples = [Float](repeating: 0, count: 16_000)
        let output = try await transcriber.transcribe(samples, config: TranscriptionConfig()) { _, _ in }
        // langStats is always empty: FluidAudio's ASRResult carries no per-utterance
        // language tag (see ParakeetTranscriber.transcribe).
        XCTAssertTrue(output.langStats.isEmpty)
    }
}
