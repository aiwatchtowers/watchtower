import XCTest
import GRDB
@testable import WatchtowerDesktop

final class MeetingChatMemoryPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() }
        catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeTranscript(eventID: String?) throws -> MeetingTranscript {
        // SQLite's IS is NULL-safe equality (unlike =, which never matches a
        // bound NULL), so this one query correctly fetches both the ad-hoc
        // (eventID == nil) and event-linked cases.
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, eventID: eventID, transcriptText: "hello world")
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in
            try MeetingTranscript.fetchOne(db, sql: "SELECT * FROM meeting_transcripts WHERE event_id IS ? ORDER BY id DESC LIMIT 1", arguments: [eventID])
        })
    }

    func testAdHocRecordingWithNoEventYieldsEmptySubjects() throws {
        let transcript = try makeTranscript(eventID: nil)
        let subjects = MeetingChatViewModel.meetingMemorySubjects(transcript: transcript, dbPool: dbManager.dbPool)
        XCTAssertTrue(subjects.isEmpty)
    }

    func testEventLinkedRecordingCollectsAttendeeSlackIDsAndEmails() throws {
        let attendeesJSON = """
        [{"email":"alice@example.com","display_name":"Alice","response_status":"accepted","slack_user_id":"U1"},
         {"email":"bob@example.com","display_name":"Bob","response_status":"accepted","slack_user_id":""}]
        """
        try dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt_1", attendees: attendeesJSON)
        }
        let transcript = try makeTranscript(eventID: "evt_1")
        let subjects = Set(MeetingChatViewModel.meetingMemorySubjects(transcript: transcript, dbPool: dbManager.dbPool))
        XCTAssertEqual(subjects, Set(["U1", "alice@example.com", "bob@example.com"]),
                       "an attendee with no resolved Slack id still contributes its email")
    }

    func testDeletedEventYieldsEmptySubjectsNotAnError() throws {
        // `meeting_transcripts.event_id` has an `ON DELETE SET NULL` FK, so a
        // normal delete auto-nulls it — can't happen live. Simulate a
        // dangling reference (legacy data / FK added after existing rows)
        // by disabling FK enforcement just for the delete.
        try dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt_1", attendees: "[]")
        }
        let transcript = try makeTranscript(eventID: "evt_1")
        try dbManager.dbPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM calendar_events WHERE id = ?", arguments: ["evt_1"])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let subjects = MeetingChatViewModel.meetingMemorySubjects(transcript: transcript, dbPool: dbManager.dbPool)
        XCTAssertTrue(subjects.isEmpty)
    }

    func testMemoryBlockAppearsWhenFlagOnAndAttendeeMatches() throws {
        let attendeesJSON = #"[{"email":"alice@example.com","display_name":"Alice","response_status":"accepted","slack_user_id":"U1"}]"#
        try dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt_1", attendees: attendeesJSON)
            try TestDatabase.insertMemoryNode(db, id: "ent_alice", type: "entity", title: "Alice (backend)")
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_alice")
        }
        let transcript = try makeTranscript(eventID: "evt_1")
        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: true, memoryVaultDir: nil)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Alice (backend)"))
    }

    func testMemoryBlockAbsentWhenFlagOff() throws {
        let transcript = try makeTranscript(eventID: nil)
        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil)
        XCTAssertFalse(prompt.contains("=== MEMORY ("))
    }
}
