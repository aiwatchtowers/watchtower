import XCTest
@testable import WatchtowerCore

final class ClipTranscriptTests: XCTestCase {
    private func utterance(
        _ idx: Int, _ start: Double, _ end: Double, _ speaker: String, _ text: String, deleted: Bool = false
    ) -> TranscriptUtterance {
        TranscriptUtterance(idx: idx, startSec: start, endSec: end, speaker: speaker, text: text, deleted: deleted)
    }

    func testClipCoveringTheWholeUtteranceShowsItWhole() {
        let text = ClipTranscript.text(
            for: ClipSpan(start: 0, end: 10), speaker: "A", utterances: [utterance(0, 1, 6, "A", "hi there")])
        XCTAssertEqual(text, "hi there")
    }

    // Ten words over 10 s: a clip over seconds 3...6 holds words 4-6 (their
    // midpoints 3.5/4.5/5.5), marked as cut on both sides.
    func testClipInsideALongUtteranceShowsOnlyItsWords() {
        let words = (1...10).map { "w\($0)" }.joined(separator: " ")
        let text = ClipTranscript.text(
            for: ClipSpan(start: 3, end: 6), speaker: "A", utterances: [utterance(0, 0, 10, "A", words)])
        XCTAssertEqual(text, "…w4 w5 w6…")
    }

    func testOtherSpeakersAndDeletedUtterancesAreLeftOut() {
        let text = ClipTranscript.text(
            for: ClipSpan(start: 0, end: 10), speaker: "A",
            utterances: [
                utterance(0, 0, 3, "B", "not mine"),
                utterance(1, 3, 5, "A", "gone", deleted: true),
                utterance(2, 5, 8, "A", "mine")
            ])
        XCTAssertEqual(text, "mine")
    }

    // Degenerate: a zero-length utterance still contributes its text, and
    // a clip overlapping no word midpoint yields nothing rather than a
    // stray ellipsis.
    func testDegenerateUtterances() {
        XCTAssertEqual(ClipTranscript.text(
            for: ClipSpan(start: 0, end: 10), speaker: "A", utterances: [utterance(0, 4, 4, "A", "blip")]), "blip")
        XCTAssertEqual(ClipTranscript.text(
            for: ClipSpan(start: 0.1, end: 0.2), speaker: "A", utterances: [utterance(0, 0, 10, "A", "one two")]), "")
    }
}
