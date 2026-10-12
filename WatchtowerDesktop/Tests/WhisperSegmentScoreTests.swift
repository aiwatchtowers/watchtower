import XCTest
import WatchtowerCore
import WhisperKit
@testable import WatchtowerDesktop

/// L3 judges each segment by its own text tokens: WhisperKit 0.18 copies one
/// pass's avgLogprob and compressionRatio onto every segment of the pass.
final class WhisperSegmentScoreTests: XCTestCase {
    private let begin = 50_257 // first special token; timestamps sit above it
    private let timestamp = 50_365

    /// Realistic text-token ids (spread over the vocabulary): small ids
    /// compress well as Int32 bytes whatever their order.
    private func speechTokens(_ count: Int) -> [Int] {
        var state: UInt64 = 0x2545F4914F6CDD1D
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 300 + Int(state >> 33) % 49_000
        }
    }

    private func score(
        _ tokens: [Int],
        _ logprobs: [[Int: Float]],
        passLogprob: Float = -0.2,
        passRatio: Float = 1.1
    ) -> WhisperSegmentScore {
        WhisperKitEngine.segmentScore(tokens: tokens, tokenLogProbs: logprobs, specialTokenBegin: begin,
                                      passAvgLogprob: passLogprob, passCompressionRatio: passRatio)
    }

    func testSpecialAndTimestampTokensAreExcluded() {
        let result = score([timestamp, 10, 20, timestamp + 50],
                           [[timestamp: -5.0], [10: -0.2], [20: -0.4], [timestamp + 50: -6.0]])
        XCTAssertEqual(result.avgLogprob, -0.3, accuracy: 1e-6)
        XCTAssertEqual(result.compressionRatio, TextUtilities.compressionRatio(of: [10, 20]))
    }

    func testSegmentWithoutTextTokensFallsBackToThePass() {
        XCTAssertEqual(score([timestamp], [[timestamp: -4.0]]), WhisperSegmentScore(avgLogprob: -0.2, compressionRatio: 1.1))
        XCTAssertEqual(score([], []), WhisperSegmentScore(avgLogprob: -0.2, compressionRatio: 1.1))
    }

    func testLoopingSegmentNextToACleanOneScoresDifferently() {
        let clean = speechTokens(60)
        let loop = Array(repeating: [1_734, 21_002, 9_455], count: 20).flatMap { $0 }
        let cleanRatio = score(clean, clean.map { [$0: -0.1] }).compressionRatio
        let loopRatio = score(loop, loop.map { [$0: -0.1] }).compressionRatio
        XCTAssertLessThanOrEqual(cleanRatio, WhisperSegmentConfidence.compressionRatioThreshold)
        XCTAssertGreaterThan(loopRatio, WhisperSegmentConfidence.compressionRatioThreshold)
    }

    func testOnlyTheLoopingSegmentOfAPassIsDropped() {
        // Both segments carry the pass's shared values (WhisperKit 0.18); the
        // pass ratio is high because of the loop, yet the clean speech stays.
        let clean = speechTokens(60)
        let loop = Array(repeating: [1_734, 21_002, 9_455], count: 20).flatMap { $0 }
        let segments = [
            TranscriptionSegment(start: 0, end: 5, text: "real speech", tokens: clean,
                                 tokenLogProbs: clean.map { [$0: -0.1] }, avgLogprob: -0.1, compressionRatio: 3.0),
            TranscriptionSegment(start: 5, end: 9, text: "loop loop loop", tokens: loop,
                                 tokenLogProbs: loop.map { [$0: -0.1] }, avgLogprob: -0.1, compressionRatio: 3.0)
        ]
        let result = WhisperKitEngine.confidentSegments(segments, specialTokenBegin: begin)
        XCTAssertEqual(result.segments.map(\.text), ["real speech"])
        XCTAssertEqual(result.counts.confidence, 1)

        // With the speech gate off (kill switch, dictation) L3 keeps everything.
        let ungated = WhisperKitEngine.confidentSegments(segments, specialTokenBegin: begin, dropDoubtful: false)
        XCTAssertEqual(ungated.segments.map(\.text), ["real speech", "loop loop loop"])
        XCTAssertEqual(ungated.counts, WindowDropCounts())
    }
}
