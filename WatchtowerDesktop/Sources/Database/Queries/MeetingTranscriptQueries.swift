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
    /// Perf guard: the heavy blobs — transcript_text, summary_json and
    /// segments_json — are NEVER selected here, only a 200-char snippet plus
    /// booleans.
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

    /// Direct notes write from the editor (GRDB, no CLI round-trip — same
    /// local-write precedent as `linkToEvent`).
    static func saveNotes(_ db: Database, id: Int64, markdown: String) throws {
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET notes_md = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [markdown, id])
    }

    /// Soft-deletes (or restores, `deleted: false` — the undo toast) one
    /// utterance: flips its `deleted` flag and rewrites `segments_json`
    /// together with the rebuilt `transcript_text` in the caller's write
    /// transaction (the `saveNotes` direct-GRDB-write precedent), preserving
    /// the invariant transcript_text = render(segments where !deleted).
    /// `TranscriptSegments.render` is the canonical renderer for UI edits;
    /// its CLI-write twin is Go's `internal/meeting.RenderTranscriptSegments`
    /// (deliberate dual-path). No-op when the row is missing, has no
    /// segments, or the idx is unknown. Deleting every utterance is valid and
    /// yields an empty transcript_text (no hard deletion ever).
    static func setUtteranceDeleted(_ db: Database, id: Int64, idx: Int, deleted: Bool) throws {
        guard let transcript = try fetch(db, id: id),
              let segmentsJSON = transcript.segmentsJSON,
              var utterances = TranscriptSegments.decode(segmentsJSON),
              let position = utterances.firstIndex(where: { $0.idx == idx }) else { return }
        utterances[position].deleted = deleted
        guard let updatedJSON = TranscriptSegments.encode(utterances) else { return }
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET segments_json = ?, transcript_text = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [updatedJSON, TranscriptSegments.render(utterances), id])
    }

    /// Deletes a recording with all its content: the transcript row and its
    /// "meeting" chat conversation (+ messages). The event's `meeting_recaps`
    /// row is deliberately NOT touched — a recap can exist independently of
    /// the recording (safe delete scope). Returns the audio_path (if any) so
    /// the caller can remove the file AFTER the transaction commits;
    /// callers must treat a missing file as success (daemon retention may
    /// have swept it already).
    static func delete(_ db: Database, id: Int64) throws -> String? {
        guard let transcript = try fetch(db, id: id) else { return nil }
        if let conv = try ChatConversationQueries.fetchByContext(db, type: "meeting", id: String(id)) {
            try ChatMessageQueries.deleteByConversation(db, conversationID: conv.id)
            try ChatConversationQueries.delete(db, id: conv.id)
        }
        try db.execute(sql: "DELETE FROM meeting_transcripts WHERE id = ?", arguments: [id])
        return transcript.audioPath
    }
}
