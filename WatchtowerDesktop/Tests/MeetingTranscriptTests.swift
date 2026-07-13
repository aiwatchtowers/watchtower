import XCTest
@testable import WatchtowerDesktop

final class MeetingTranscriptTests: XCTestCase {
    private func makeTranscript(summaryJSON: String?) -> MeetingTranscript {
        MeetingTranscript(
            id: 1,
            eventID: nil,
            title: "Rec",
            audioPath: nil,
            durationSec: 60,
            langStats: "",
            transcriptText: "text",
            summaryJSON: summaryJSON,
            createdAt: "2026-07-13T10:00:00Z",
            updatedAt: "2026-07-13T10:00:00Z"
        )
    }

    func test_parsedSummaryDecodesSnakeCaseJSON() throws {
        let transcript = makeTranscript(
            summaryJSON: #"{"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}"#
        )
        let parsed = try XCTUnwrap(transcript.parsedSummary)
        XCTAssertEqual(parsed.summary, "s")
        XCTAssertEqual(parsed.keyDecisions, ["d"])
        XCTAssertTrue(parsed.actionItems.isEmpty)
        XCTAssertTrue(parsed.openQuestions.isEmpty)
    }

    func test_parsedSummaryReturnsNilForNilJSON() {
        let transcript = makeTranscript(summaryJSON: nil)
        XCTAssertNil(transcript.parsedSummary)
    }

    func test_parsedSummaryReturnsNilForMalformedJSON() {
        let transcript = makeTranscript(summaryJSON: "not json")
        XCTAssertNil(transcript.parsedSummary)
    }
}
