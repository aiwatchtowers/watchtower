import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

final class RecapRefreshHintTests: XCTestCase {
    private func transcript(
        summaryJSON: String? = #"{"summary":"s"}"#,
        updatedAt: String = "2026-09-28T10:00:00Z",
        namesChangedAt: String?,
        summaryUpdatedAt: String?
    ) -> MeetingTranscript {
        MeetingTranscript(
            id: 1, eventID: nil, title: "t", audioPath: nil, durationSec: 60, langStats: "",
            transcriptText: "x", summaryJSON: summaryJSON, notesMD: nil, segmentsJSON: nil,
            speakersJSON: nil, chaptersJSON: nil, createdAt: "2026-09-28T09:00:00Z", updatedAt: updatedAt,
            speakerNamesChangedAt: namesChangedAt, summaryUpdatedAt: summaryUpdatedAt)
    }

    func testNoRelabelNeverHints() {
        XCTAssertFalse(transcript(namesChangedAt: nil, summaryUpdatedAt: nil)
            .recapPredatesSpeakerNames(shownRecap: nil))
    }

    /// The bug this pins: a relabel stamps `updated_at` and
    /// `speaker_names_changed_at` equal, so comparing with `updated_at` never fired.
    func testRelabelStampingUpdatedAtStillHints() {
        let t = transcript(updatedAt: "2026-09-28T10:00:00Z", namesChangedAt: "2026-09-28T10:00:00Z",
                           summaryUpdatedAt: "2026-09-28T09:30:00Z")
        XCTAssertTrue(t.recapPredatesSpeakerNames(shownRecap: nil))
    }

    func testRecapRegeneratedAfterRelabelHidesHint() {
        let t = transcript(namesChangedAt: "2026-09-28T10:00:00Z", summaryUpdatedAt: "2026-09-28T10:05:00Z")
        XCTAssertFalse(t.recapPredatesSpeakerNames(shownRecap: nil))
    }

    func testLegacyUnstampedSummaryIsOlderThanAnyRelabel() {
        let t = transcript(namesChangedAt: "2026-09-28T10:00:00Z", summaryUpdatedAt: nil)
        XCTAssertTrue(t.recapPredatesSpeakerNames(shownRecap: nil))
    }

    func testNoRecapNothingToRegenerate() {
        let t = transcript(summaryJSON: nil, namesChangedAt: "2026-09-28T10:00:00Z", summaryUpdatedAt: nil)
        XCTAssertFalse(t.recapPredatesSpeakerNames(shownRecap: nil))
    }

    private func recapRow(updatedAt: String) -> MeetingRecap {
        MeetingRecap(eventID: "evt-1", sourceText: "x", recapJSON: #"{"summary":"r"}"#,
                     createdAt: updatedAt, updatedAt: updatedAt)
    }

    func testOwnRecapRowComparesWithItsOwnTimestamp() {
        let t = transcript(summaryJSON: nil, namesChangedAt: "2026-09-28T10:00:00Z", summaryUpdatedAt: nil)
        let old = RecordingRecap(recap: recapRow(updatedAt: "2026-09-28T09:00:00Z"), ownedByRecording: true)
        let fresh = RecordingRecap(recap: recapRow(updatedAt: "2026-09-28T11:00:00Z"), ownedByRecording: true)
        XCTAssertTrue(t.recapPredatesSpeakerNames(shownRecap: old))
        XCTAssertFalse(t.recapPredatesSpeakerNames(shownRecap: fresh))
    }

    /// A pasted / another recording's event recap: the Regenerate cannot
    /// replace it (collision guard), so the hint would never clear.
    func testForeignEventRecapNeverHints() {
        let t = transcript(summaryJSON: nil, namesChangedAt: "2026-09-28T10:00:00Z", summaryUpdatedAt: nil)
        let foreign = RecordingRecap(recap: recapRow(updatedAt: "2026-09-28T09:00:00Z"), ownedByRecording: false)
        XCTAssertFalse(t.recapPredatesSpeakerNames(shownRecap: foreign))
    }

    /// An own row that also has a summary copy (linkToEvent) reads the
    /// summary's generation stamp, not the row's link-time `updated_at`.
    func testOwnRowWithSummaryCopyUsesTheSummaryStamp() {
        let t = transcript(namesChangedAt: "2026-09-28T10:00:00Z", summaryUpdatedAt: "2026-09-28T09:00:00Z")
        let linkedLater = RecordingRecap(recap: recapRow(updatedAt: "2026-09-28T12:00:00Z"), ownedByRecording: true)
        XCTAssertTrue(t.recapPredatesSpeakerNames(shownRecap: linkedLater))
    }

    // MARK: - On the real rows (fetchForRecording + hint)

    private func hint(_ db: DatabaseQueue, transcriptID: Int64 = 1) throws -> Bool {
        try db.read { conn in
            let row = try XCTUnwrap(try MeetingTranscript.fetchOne(conn, key: transcriptID))
            let shown = try MeetingRecapQueries.fetchForRecording(
                conn, transcriptID: transcriptID, eventID: row.eventID)
            return row.recapPredatesSpeakerNames(shownRecap: shown)
        }
    }

    /// N1: an event-linked recording whose save wrote the event's recap row
    /// (transcript_id = its id). A relabel turns the hint on; Go's
    /// `transcript recap <id>` refreshing that row in place turns it off.
    func testEventLinkedOwnRecapHintClearsWhenTheRowIsRegenerated() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertCalendarEvent(conn, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(conn, id: 1, eventID: "evt-1")
            try TestDatabase.insertMeetingRecap(conn, eventID: "evt-1", transcriptID: 1,
                                                createdAt: "2026-09-28T09:00:00Z")
            try conn.execute(sql: "UPDATE meeting_transcripts SET speaker_names_changed_at = '2026-09-28T10:00:00Z'")
        }
        XCTAssertTrue(try hint(db))
        try db.write { conn in  // what UpdateMeetingRecapContent writes
            try conn.execute(sql: "UPDATE meeting_recaps SET updated_at = '2026-09-28T10:05:00Z'")
        }
        XCTAssertFalse(try hint(db))
    }

    /// An ad-hoc recording whose recap row is linked only by transcript_id
    /// (its event was deleted) is this recording's own too.
    func testOrphanOwnRecapResolvesAsOwned() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertMeetingTranscript(conn, id: 1)
            try TestDatabase.insertMeetingRecap(conn, eventID: nil, transcriptID: 1,
                                                createdAt: "2026-09-28T09:00:00Z")
            try conn.execute(sql: "UPDATE meeting_transcripts SET speaker_names_changed_at = '2026-09-28T10:00:00Z'")
        }
        let shown = try db.read { try MeetingRecapQueries.fetchForRecording($0, transcriptID: 1, eventID: nil) }
        XCTAssertEqual(shown?.ownedByRecording, true)
        XCTAssertTrue(try hint(db))
    }

    func testPastedEventRecapResolvesAsForeignAndNeverHints() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertCalendarEvent(conn, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(conn, id: 1, eventID: "evt-1")
            try TestDatabase.insertMeetingRecap(conn, eventID: "evt-1", transcriptID: nil,
                                                createdAt: "2026-09-28T09:00:00Z")
            try conn.execute(sql: "UPDATE meeting_transcripts SET speaker_names_changed_at = '2026-09-28T10:00:00Z'")
        }
        let shown = try db.read { try MeetingRecapQueries.fetchForRecording($0, transcriptID: 1, eventID: "evt-1") }
        XCTAssertEqual(shown?.ownedByRecording, false)
        XCTAssertFalse(try hint(db))
    }
}
