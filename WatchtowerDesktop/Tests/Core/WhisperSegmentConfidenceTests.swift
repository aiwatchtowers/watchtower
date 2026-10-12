import XCTest
@testable import WatchtowerCore

final class WhisperSegmentConfidenceTests: XCTestCase {
    private func drops(_ noSpeech: Float, _ logprob: Float, _ compression: Float) -> Bool {
        WhisperSegmentConfidence.dropReason(noSpeechProb: noSpeech, avgLogprob: logprob, compressionRatio: compression) != nil
    }

    func testNoSpeechWithLowConfidenceDrops() {
        XCTAssertTrue(drops(0.7, -1.2, 1.5))
        XCTAssertEqual(WhisperSegmentConfidence.dropReason(noSpeechProb: 0.7, avgLogprob: -1.2, compressionRatio: 1.5),
                       .noSpeech)
    }

    func testNoSpeechWithConfidentTextKeeps() {
        XCTAssertFalse(drops(0.7, -0.5, 1.5))
    }

    func testSpeechWithModestConfidenceKeeps() {
        XCTAssertFalse(drops(0.2, -1.2, 1.5))
    }

    func testRepetitiveTextDrops() {
        XCTAssertTrue(drops(0.1, -0.3, 2.6))
        XCTAssertEqual(WhisperSegmentConfidence.dropReason(noSpeechProb: 0.1, avgLogprob: -0.3, compressionRatio: 2.6),
                       .repetition)
    }

    func testVeryLowConfidenceDropsWhateverTheNoSpeechHead() {
        XCTAssertTrue(drops(0.1, -1.7, 1.5))
        XCTAssertEqual(WhisperSegmentConfidence.dropReason(noSpeechProb: 0.1, avgLogprob: -1.7, compressionRatio: 1.5),
                       .lowLogprob)
    }

    func testValuesExactlyAtTheThresholdsKeep() {
        XCTAssertFalse(drops(0.6, -1.2, 1.5), "noSpeech at 0.6 is not above it")
        XCTAssertFalse(drops(0.7, -1.0, 1.5), "logprob at -1.0 is not below it")
        XCTAssertFalse(drops(0.1, -0.3, 2.4), "compression at 2.4 is not above it")
        XCTAssertFalse(drops(0.1, WhisperSegmentConfidence.minAvgLogprob, 1.5), "logprob at the cut-off is not below it")
    }
}
