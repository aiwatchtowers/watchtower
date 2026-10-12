import XCTest
@testable import WatchtowerCore

final class TranscriptBenchMetricsTests: XCTestCase {
    private typealias Metrics = TranscriptBenchMetrics

    func testWERIsZeroOnIdenticalText() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "the cat sat down", hypothesis: "the cat sat down"), 0)
    }

    func testOneSubstitutionInFourWordsIsAQuarter() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "the cat sat down", hypothesis: "the dog sat down"), 0.25)
    }

    func testEmptyHypothesisIsFullError() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "the cat sat down", hypothesis: ""), 1.0)
    }

    func testEmptyReferenceScoresZeroOnlyForEmptyHypothesis() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(Metrics.wordErrorRate(reference: "", hypothesis: "hello"), 1)
    }

    func testPunctuationAndCaseAreIgnored() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "Привет, мир! Всё хорошо.", hypothesis: "привет мир все хорошо"), 0)
        XCTAssertEqual(Metrics.words("Hello, World... it's 25!"), ["hello", "world", "it", "s", "25"])
    }

    func testInsertedWordsCountsOnlyExtraWords() {
        XCTAssertEqual(Metrics.insertedWords(reference: "one two", hypothesis: "one thanks for watching two"), 3)
        XCTAssertEqual(Metrics.insertedWords(reference: "one two", hypothesis: "one three"), 0)
        XCTAssertEqual(Metrics.insertedWords(reference: "", hypothesis: "a b"), 2)
        XCTAssertEqual(Metrics.insertedWords(reference: "one two", hypothesis: ""), 0)
    }

    func testWordsInFillerCountsByMidpointWithTolerance() {
        let filler = [10.0...70.0]
        let segments = [
            Metrics.Segment(text: "real speech here", startSec: 7, endSec: 10.6),      // mid 8.8: speech
            Metrics.Segment(text: "drifted tail", startSec: 9.8, endSec: 10.6),        // mid 10.2: inside tolerance
            Metrics.Segment(text: "thanks for watching", startSec: 10.2, endSec: 11),  // mid 10.6: filler
            Metrics.Segment(text: "Продолжение следует...", startSec: 40, endSec: 42), // filler
            Metrics.Segment(text: "early head", startSec: 69.4, endSec: 69.8),         // mid 69.6: inside tolerance
            Metrics.Segment(text: "speech b", startSec: 70, endSec: 74)                // speech
        ]
        XCTAssertEqual(Metrics.wordsInFiller(segments: segments, fillers: filler), 5)
    }

    func testWordsInFillerWithNoFillerIsZero() {
        let segments = [Metrics.Segment(text: "a b c", startSec: 0, endSec: 2)]
        XCTAssertEqual(Metrics.wordsInFiller(segments: segments, fillers: []), 0)
    }
}
