import XCTest
@testable import WatchtowerDesktop

/// The engine-side seam of `WhisperHallucinationFilter`: what a WhisperKit
/// window hands the transcribers after cleaning.
final class TranscribedSegmentHallucinationTests: XCTestCase {
    func testCreditOnlySegmentsVanishAndRealOnesKeepTheirTimes() {
        let segments = [
            TranscribedSegment(text: "Давай начнём.", startSec: 0, endSec: 4),
            TranscribedSegment(text: "Продолжение следует... Продолжение следует...", startSec: 4, endSec: 30),
            TranscribedSegment(text: "Субтитры сделал DimaTorzok Итак, вопрос.", startSec: 30, endSec: 33)
        ]

        XCTAssertEqual(segments.withoutHallucinations(), [
            TranscribedSegment(text: "Давай начнём.", startSec: 0, endSec: 4),
            TranscribedSegment(text: "Итак, вопрос.", startSec: 30, endSec: 33)
        ])
    }

    // Degenerate: a window of nothing but credits reads as silence — the
    // engine contract's "empty array = no speech".
    func testAllCreditWindowIsSilence() {
        XCTAssertEqual([TranscribedSegment(text: "Thanks for watching!", startSec: 0, endSec: 30)].withoutHallucinations(), [])
        XCTAssertEqual([TranscribedSegment]().withoutHallucinations(), [])
    }
}
