import XCTest
@testable import WatchtowerDesktop

final class TranscriptFormattingTests: XCTestCase {
    func test_formatDurationUnderAMinute() {
        XCTAssertEqual(TranscriptFormatting.formatDuration(45), "45s")
    }

    func test_formatDurationOverAMinute() {
        XCTAssertEqual(TranscriptFormatting.formatDuration(125), "2m 5s")
    }

    func test_formatDurationZero() {
        XCTAssertEqual(TranscriptFormatting.formatDuration(0), "0s")
    }

    func test_formatTimecodeUnderAnHour() {
        XCTAssertEqual(TranscriptFormatting.formatTimecode(0), "0:00")
        XCTAssertEqual(TranscriptFormatting.formatTimecode(5.9), "0:05")
        XCTAssertEqual(TranscriptFormatting.formatTimecode(65), "1:05")
        XCTAssertEqual(TranscriptFormatting.formatTimecode(754.4), "12:34")
    }

    func test_formatTimecodePastAnHour() {
        XCTAssertEqual(TranscriptFormatting.formatTimecode(3600), "1:00:00")
        XCTAssertEqual(TranscriptFormatting.formatTimecode(3725), "1:02:05")
    }

    func test_formatTimecodeClampsNegative() {
        XCTAssertEqual(TranscriptFormatting.formatTimecode(-3), "0:00")
    }

    func test_formattedDateParsesISO8601() {
        let result = TranscriptFormatting.formattedDate("2026-07-15T10:30:00Z")
        XCTAssertFalse(result.isEmpty)
        XCTAssertNotEqual(result, "2026-07-15T10:30:00Z")
    }

    func test_formattedDateFallsBackToRawStringWhenUnparseable() {
        XCTAssertEqual(TranscriptFormatting.formattedDate("not-a-date"), "not-a-date")
    }

    func test_decodeLangStatsSortsDescendingByCount() {
        let json = #"{"en":2,"ru":5,"uk":1}"#
        let result = TranscriptFormatting.decodeLangStats(json)
        XCTAssertEqual(result.map(\.0), ["ru", "en", "uk"])
        XCTAssertEqual(result.map(\.1), [5, 2, 1])
    }

    func test_decodeLangStatsReturnsEmptyForInvalidJSON() {
        XCTAssertTrue(TranscriptFormatting.decodeLangStats("not json").isEmpty)
    }
}
