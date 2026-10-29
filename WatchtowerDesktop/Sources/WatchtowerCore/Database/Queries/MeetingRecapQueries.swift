import Foundation
import GRDB

package enum MeetingRecapQueries {
    package static func fetch(_ db: Database, eventID: String) throws -> MeetingRecap? {
        try MeetingRecap
            .filter(Column("event_id") == eventID)
            .fetchOne(db)
    }

    /// Recap durably linked to a recording via `meeting_recaps.transcript_id`.
    /// This link survives the event's deletion (event_id goes NULL on both the
    /// event and the recap), so it is resolved AHEAD of the event_id lookup —
    /// an event-deleted recording still shows its recap. `transcript_id` is not
    /// in `MeetingRecap`'s CodingKeys; FetchableRecord ignores the extra column.
    package static func fetch(_ db: Database, transcriptID: Int64) throws -> MeetingRecap? {
        try MeetingRecap
            .filter(Column("transcript_id") == transcriptID)
            .fetchOne(db)
    }

    /// The recap row a recording's Recap tab renders: the durable
    /// `transcript_id` link first (it survives the event's deletion), then
    /// the event's row. Nil = the tab falls back to the transcript's own
    /// `summary_json`. Go's `storeTranscriptRecap` (cmd/meeting_transcript.go)
    /// writes to the same precedence — keep the two in step.
    package static func fetchForRecording(
        _ db: Database, transcriptID: Int64, eventID: String?
    ) throws -> RecordingRecap? {
        if let own = try fetch(db, transcriptID: transcriptID) {
            return RecordingRecap(recap: own, ownedByRecording: true)
        }
        guard let eventID, let eventRecap = try fetch(db, eventID: eventID) else { return nil }
        return RecordingRecap(recap: eventRecap, ownedByRecording: false)
    }

    /// Swift twin of Go's `db.RecapNotPrivate` (MEETPRIV-02), over
    /// `meeting_recaps` unaliased: keeps a recap unless the recording owning
    /// it (`transcript_id`) is private. A recap with no owning recording
    /// (pasted text) is kept.
    static let recapNotPrivateSQL = """
        NOT EXISTS (SELECT 1 FROM meeting_transcripts pt \
        WHERE pt.id = meeting_recaps.transcript_id AND pt.private = 1)
        """

    /// `fetchForRecording` for a reader whose output reaches a model (the
    /// meeting chat's prompt): a recap owned by a private recording reads as
    /// none — Go's `GetMeetingRecapForAI` (MEETPRIV-02). The Recap tab keeps
    /// the plain lookup: it is the owner's own, local view.
    package static func fetchForRecordingForAI(
        _ db: Database, transcriptID: Int64, eventID: String?
    ) throws -> RecordingRecap? {
        if let own = try MeetingRecap
            .filter(Column("transcript_id") == transcriptID)
            .filter(sql: recapNotPrivateSQL)
            .fetchOne(db) {
            return RecordingRecap(recap: own, ownedByRecording: true)
        }
        guard let eventID,
              let eventRecap = try MeetingRecap
                .filter(Column("event_id") == eventID)
                .filter(sql: recapNotPrivateSQL)
                .fetchOne(db)
        else { return nil }
        return RecordingRecap(recap: eventRecap, ownedByRecording: false)
    }

    /// Whether the event's recap belongs to a private recording
    /// (MEETPRIV-01/02): the event page shows it locally but offers no AI
    /// action on it — no Re-generate, no "+ to notes", no task.
    package static func isOwnedByPrivateRecording(_ db: Database, eventID: String) throws -> Bool {
        try MeetingRecap
            .filter(Column("event_id") == eventID)
            .filter(sql: "NOT (\(recapNotPrivateSQL))")
            .fetchCount(db) > 0
    }

    /// One recap by row id — how a Catch-Up recap resolves a `recaps` ref (the
    /// ref area the Go gather emits for `meeting_recaps`).
    package static func fetchByID(_ db: Database, id: Int) throws -> MeetingRecap? {
        try MeetingRecap
            .filter(Column("id") == id)
            .fetchOne(db)
    }
}
