import Foundation
import GRDB

enum MeetingTranscriptQueries {
    static func fetch(_ db: Database, id: Int64) throws -> MeetingTranscript? {
        try MeetingTranscript.fetchOne(db, key: id)
    }

    /// Transcripts linked to a calendar event, newest first.
    static func fetchForEvent(_ db: Database, eventID: String) throws -> [MeetingTranscript] {
        try MeetingTranscript
            .filter(Column("event_id") == eventID)
            .order(Column("created_at").desc, Column("id").desc)
            .fetchAll(db)
    }

    /// Ad-hoc transcripts (no calendar event), newest first.
    static func fetchAdHoc(_ db: Database, limit: Int = 50) throws -> [MeetingTranscript] {
        try MeetingTranscript
            .filter(Column("event_id") == nil)
            .order(Column("created_at").desc, Column("id").desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// Dual-path write (documented pattern, cf. `CatchUpQueries.acknowledge`):
    /// links the transcript to the event; if the event has no `meeting_recaps`
    /// row and the transcript carries a summary, copies it into
    /// `meeting_recaps` (`source_text` = transcript text) so the recap shows up
    /// in the existing recap UI immediately.
    static func linkToEvent(_ db: Database, id: Int64, eventID: String) throws {
        guard let transcript = try fetch(db, id: id) else { return }
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET event_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [eventID, id])
        guard let summaryJSON = transcript.summaryJSON, !summaryJSON.isEmpty else { return }
        guard try MeetingRecapQueries.fetch(db, eventID: eventID) == nil else { return }
        try db.execute(
            sql: """
                INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at, updated_at)
                VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                """,
            arguments: [eventID, transcript.transcriptText, summaryJSON])
    }

    /// Recordings master list (ad-hoc + event-linked), newest first. A recap
    /// "exists" when the row has summary_json OR its event has a
    /// meeting_recaps row (the recap collision guard can put it in either).
    static func fetchRecordingList(_ db: Database, limit: Int = 200) throws -> [RecordingListItem] {
        try RecordingListItem.fetchAll(
            db,
            sql: """
                SELECT t.id, t.event_id, t.title, t.duration_sec, t.lang_stats, t.created_at,
                       (t.summary_json IS NOT NULL
                        OR EXISTS (SELECT 1 FROM meeting_recaps r WHERE r.event_id = t.event_id)) AS has_recap,
                       (t.notes_md IS NOT NULL) AS has_notes,
                       substr(t.transcript_text, 1, 200) AS snippet
                FROM meeting_transcripts t
                ORDER BY t.created_at DESC, t.id DESC
                LIMIT ?
                """,
            arguments: [limit])
    }
}
