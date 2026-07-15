import GRDB
import XCTest
@testable import WatchtowerDesktop

final class MeetingTranscriptQueriesTests: XCTestCase {
    private let summaryJSON =
        #"{"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}"#

    func test_fetchReturnsRowByID() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, id: 7, title: "Standup", transcriptText: "hello")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 7))
            XCTAssertEqual(transcript.id, 7)
            XCTAssertEqual(transcript.title, "Standup")
            XCTAssertEqual(transcript.transcriptText, "hello")
            XCTAssertNil(transcript.eventID)
            XCTAssertNil(try MeetingTranscriptQueries.fetch(db, id: 999))
        }
    }

    func test_fetchForEventReturnsOnlyThatEventNewestFirst() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertCalendarEvent(db, id: "evt-2")
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "older")
            try TestDatabase.insertMeetingTranscript(db, id: 2, eventID: "evt-1", title: "newer")
            try TestDatabase.insertMeetingTranscript(db, id: 3, eventID: "evt-2", title: "other event")
            try TestDatabase.insertMeetingTranscript(db, id: 4, title: "ad-hoc")
        }
        try db.read { db in
            let rows = try MeetingTranscriptQueries.fetchForEvent(db, eventID: "evt-1")
            XCTAssertEqual(rows.map(\.id), [2, 1])
            XCTAssertEqual(rows.map(\.title), ["newer", "older"])
        }
    }

    func test_fetchAdHocReturnsOnlyNullEventRowsNewestFirst() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(db, id: 1, title: "first ad-hoc")
            try TestDatabase.insertMeetingTranscript(db, id: 2, eventID: "evt-1", title: "linked")
            try TestDatabase.insertMeetingTranscript(db, id: 3, title: "second ad-hoc")
        }
        try db.read { db in
            let rows = try MeetingTranscriptQueries.fetchAdHoc(db)
            XCTAssertEqual(rows.map(\.id), [3, 1])
            XCTAssertTrue(rows.allSatisfy { $0.eventID == nil })
        }
    }

    func test_fetchAdHocRespectsLimit() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            for i in Int64(1)...5 {
                try TestDatabase.insertMeetingTranscript(db, id: i)
            }
        }
        try db.read { db in
            let rows = try MeetingTranscriptQueries.fetchAdHoc(db, limit: 2)
            XCTAssertEqual(rows.map(\.id), [5, 4])
        }
    }

    func test_linkToEventCopiesSummaryIntoRecapWhenNoneExists() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "Rec", transcriptText: "spoken words",
                summaryJSON: summaryJSON)
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(transcript.eventID, "evt-1")
            let recap = try XCTUnwrap(MeetingRecapQueries.fetch(db, eventID: "evt-1"))
            XCTAssertEqual(recap.recapJSON, self.summaryJSON)
            XCTAssertEqual(recap.sourceText, "spoken words")
        }
    }

    func test_linkToEventLeavesExistingRecapUntouched() throws {
        let existingRecapJSON =
            #"{"summary":"existing","key_decisions":[],"action_items":[],"open_questions":[]}"#
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: existingRecapJSON)
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, transcriptText: "spoken words", summaryJSON: summaryJSON)
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(transcript.eventID, "evt-1")
            let recap = try XCTUnwrap(MeetingRecapQueries.fetch(db, eventID: "evt-1"))
            XCTAssertEqual(recap.recapJSON, existingRecapJSON)
            XCTAssertEqual(recap.sourceText, "")
            let recapCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM meeting_recaps") ?? -1
            XCTAssertEqual(recapCount, 1)
        }
    }

    func test_linkToEventWithoutSummaryWritesOnlyEventID() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, transcriptText: "spoken words", summaryJSON: nil)
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(transcript.eventID, "evt-1")
            XCTAssertNil(try MeetingRecapQueries.fetch(db, eventID: "evt-1"))
        }
    }

    func test_recordingListReturnsAllNewestFirstWithLightFields() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, eventID: "evt-1", title: "Linked",
                transcriptText: String(repeating: "x", count: 500))
            try TestDatabase.insertMeetingTranscript(
                db, id: 2, title: "AdHoc", transcriptText: "short",
                summaryJSON: self.summaryJSON, notesMD: "# n")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertEqual(items.map(\.id), [2, 1])
            XCTAssertEqual(items[0].title, "AdHoc")
            XCTAssertTrue(items[0].hasRecap, "summary_json counts as a recap")
            XCTAssertTrue(items[0].hasNotes)
            XCTAssertEqual(items[0].snippet, "short")
            XCTAssertFalse(items[1].hasRecap)
            XCTAssertFalse(items[1].hasNotes)
            XCTAssertEqual(items[1].snippet.count, 200, "snippet must be capped at 200 chars")
            XCTAssertEqual(items[1].eventID, "evt-1")
        }
    }

    func test_recordingListCountsEventRecapAsRecap() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: self.summaryJSON)
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "Linked")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertTrue(items[0].hasRecap, "meeting_recaps row for the linked event counts as a recap")
        }
    }
}
