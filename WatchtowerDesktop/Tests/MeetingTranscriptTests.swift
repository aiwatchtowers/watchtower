import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class MeetingTranscriptTests: XCTestCase {
    private func makeTranscript(summaryJSON: String?, segmentsJSON: String? = nil, chaptersJSON: String? = nil) -> MeetingTranscript {
        MeetingTranscript(
            id: 1,
            eventID: nil,
            title: "Rec",
            audioPath: nil,
            durationSec: 60,
            langStats: "",
            transcriptText: "text",
            summaryJSON: summaryJSON,
            notesMD: nil,
            segmentsJSON: segmentsJSON,
            speakersJSON: nil,
            chaptersJSON: chaptersJSON,
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

    func test_notesMDRoundTrips() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "With notes", notesMD: "# Notes\n- point")
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Without notes")
        }
        try db.read { db in
            let withNotes = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(withNotes.notesMD, "# Notes\n- point")
            let without = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 2))
            XCTAssertNil(without.notesMD)
        }
    }
}
