import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class MeetingRecapTests: XCTestCase {
    func test_parsedReturnsContentForValidJSON() throws {
        let recap = MeetingRecap(
            eventID: "evt-1",
            sourceText: "raw",
            recapJSON: """
            {
              "summary": "Talked about Q3.",
              "key_decisions": ["ship friday"],
              "action_items": ["draft post"],
              "open_questions": ["pricing?"]
            }
            """,
            createdAt: "2026-04-27T10:00:00Z",
            updatedAt: "2026-04-27T10:00:00Z"
        )
        let parsed = try XCTUnwrap(recap.parsed)
        XCTAssertEqual(parsed.summary, "Talked about Q3.")
        XCTAssertEqual(parsed.keyDecisions, ["ship friday"])
        XCTAssertEqual(parsed.actionItems, ["draft post"])
        XCTAssertEqual(parsed.openQuestions, ["pricing?"])
    }

    func test_parsedReturnsNilForMalformedJSON() {
        let recap = MeetingRecap(
            eventID: "x", sourceText: "", recapJSON: "not json",
            createdAt: "", updatedAt: ""
        )
        XCTAssertNil(recap.parsed)
    }

    func test_parsedDecodesSnakeCaseKeys() throws {
        let json = """
        {"summary":"s","key_decisions":[],"action_items":[],"open_questions":[]}
        """
        let recap = MeetingRecap(eventID: "x", sourceText: "", recapJSON: json,
                                 createdAt: "", updatedAt: "")
        let parsed = try XCTUnwrap(recap.parsed)
        XCTAssertEqual(parsed.summary, "s")
        XCTAssertTrue(parsed.keyDecisions.isEmpty)
    }

    // MARK: - fetchByID

    func test_fetchByIDResolvesOneRowAndNilForUnknown() throws {
        let db = try TestDatabase.create()
        let id = try db.write { db -> Int64 in
            try TestDatabase.insertMeetingRecap(db, sourceText: "other")
            try TestDatabase.insertMeetingRecap(db, sourceText: "wanted")
            return db.lastInsertedRowID
        }

        let recap = try db.read { try MeetingRecapQueries.fetchByID($0, id: Int(id)) }

        XCTAssertEqual(recap?.sourceText, "wanted")
        XCTAssertNil(try db.read { try MeetingRecapQueries.fetchByID($0, id: 9999) })
    }

    /// MEETPRIV-01/02: the calendar event page offers no AI action (no
    /// Re-generate, no prefilled `source_text`, no "+ to notes") on a recap
    /// a private recording owns — including one turned private after its
    /// recap was generated. A public recording's recap and a pasted one
    /// keep them.
    func testMeetPriv02_EventPageOffersNoAIActionOnARecapAPrivateRecordingOwns() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertCalendarEvent(conn, id: "evt-priv")
            try TestDatabase.insertCalendarEvent(conn, id: "evt-pub")
            try TestDatabase.insertCalendarEvent(conn, id: "evt-paste")
            try TestDatabase.insertMeetingTranscript(conn, id: 1, eventID: "evt-priv", isPrivate: true)
            try TestDatabase.insertMeetingTranscript(conn, id: 2, eventID: "evt-pub")
            try TestDatabase.insertMeetingRecap(conn, eventID: "evt-priv", transcriptID: 1, sourceText: "private words")
            try TestDatabase.insertMeetingRecap(conn, eventID: "evt-pub", transcriptID: 2, sourceText: "public words")
            try TestDatabase.insertMeetingRecap(conn, eventID: "evt-paste", sourceText: "pasted words")
        }
        func gateAndRecap(_ eventID: String) throws -> (EventRecapGate, MeetingRecap?) {
            try db.read { conn in
                (try EventRecapGate.load(conn, eventID: eventID), try MeetingRecapQueries.fetch(conn, eventID: eventID))
            }
        }

        let (privGate, privRecap) = try gateAndRecap("evt-priv")
        XCTAssertFalse(privGate.offersAIActions)
        XCTAssertNotNil(privRecap, "the owner still sees it locally")
        XCTAssertEqual(privGate.prefilledText(privRecap), "")

        let (pubGate, pubRecap) = try gateAndRecap("evt-pub")
        XCTAssertTrue(pubGate.offersAIActions)
        XCTAssertEqual(pubGate.prefilledText(pubRecap), "public words")

        let (pasteGate, pasteRecap) = try gateAndRecap("evt-paste")
        XCTAssertTrue(pasteGate.offersAIActions)
        XCTAssertEqual(pasteGate.prefilledText(pasteRecap), "pasted words")
        XCTAssertTrue(try gateAndRecap("evt-none").0.offersAIActions, "no recap: Recap from text stays")

        // Turned private after the recap was generated (MEETPRIV-04).
        try db.write { try $0.execute(sql: "UPDATE meeting_transcripts SET private = 1 WHERE id = 2") }
        let (flipped, flippedRecap) = try gateAndRecap("evt-pub")
        XCTAssertFalse(flipped.offersAIActions)
        XCTAssertEqual(flipped.prefilledText(flippedRecap), "")
    }

    /// MEETPRIV-02: "+ to notes" re-checks the gate at action time
    /// (`EventRecapGate.current`): a recording turned private after the page
    /// loaded closes it, and a failed read closes it too.
    func testMeetPriv02_EventRecapGateAtActionTimeFailsClosed() async throws {
        let db = try TestDatabase.create()
        try await db.write { conn in
            try TestDatabase.insertCalendarEvent(conn, id: "evt-pub")
            try TestDatabase.insertMeetingTranscript(conn, id: 2, eventID: "evt-pub")
            try TestDatabase.insertMeetingRecap(conn, eventID: "evt-pub", transcriptID: 2, sourceText: "public words")
        }
        let open = await EventRecapGate.current(db, eventID: "evt-pub")
        XCTAssertTrue(open.offersAIActions)

        try await db.write { try $0.execute(sql: "UPDATE meeting_transcripts SET private = 1 WHERE id = 2") }
        let flipped = await EventRecapGate.current(db, eventID: "evt-pub")
        XCTAssertFalse(flipped.offersAIActions)

        let unreadable = await EventRecapGate.current(try DatabaseQueue(), eventID: "evt-pub")
        XCTAssertFalse(unreadable.offersAIActions, "no meeting_recaps table: the read fails and the gate stays closed")
    }
}
