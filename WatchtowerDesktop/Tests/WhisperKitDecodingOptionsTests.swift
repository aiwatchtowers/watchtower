import XCTest
@testable import WatchtowerDesktop

/// The decode options carry every threshold L3 relies on explicitly (spec
/// D3), so a WhisperKit upgrade that moves its defaults cannot move ours.
final class WhisperKitDecodingOptionsTests: XCTestCase {
    func testOptionsPinTheConfidenceThresholds() {
        let options = WhisperKitEngine.decodingOptions(language: "ru", promptTokens: [1, 2])
        XCTAssertEqual(options.temperatureFallbackCount, 5)
        XCTAssertEqual(options.compressionRatioThreshold, 2.4)
        XCTAssertEqual(options.logProbThreshold, -1.0)
        XCTAssertEqual(options.noSpeechThreshold, 0.6)
        XCTAssertNil(options.chunkingStrategy, "our windows are already at most 30 s")
    }

    func testOptionsKeepTheWindowContract() {
        let options = WhisperKitEngine.decodingOptions(language: "uk", promptTokens: nil)
        XCTAssertEqual(options.language, "uk")
        XCTAssertFalse(options.detectLanguage, "the language is decided per window, never by the decoder")
        XCTAssertFalse(options.withoutTimestamps, "segment timestamps feed L2 and diarization")
        XCTAssertTrue(options.skipSpecialTokens)
        XCTAssertNil(options.promptTokens)
    }
}
