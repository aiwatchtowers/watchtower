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

    /// One recap by row id — how a Catch-Up recap resolves a `meetings` ref.
    package static func fetchByID(_ db: Database, id: Int) throws -> MeetingRecap? {
        try MeetingRecap
            .filter(Column("id") == id)
            .fetchOne(db)
    }
}
