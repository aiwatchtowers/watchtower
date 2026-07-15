import Foundation
import GRDB

/// Lightweight projection of `meeting_transcripts` for the Recordings master
/// list. Deliberately excludes `transcript_text` (only a 200-char snippet) and
/// `summary_json` (only a boolean) so scrolling the list never deserializes
/// megabyte blobs — mirroring the Go `transcript list` command.
struct RecordingListItem: Decodable, FetchableRecord, Identifiable, Equatable {
    let id: Int64
    let eventID: String?
    let title: String
    let durationSec: Int
    let langStats: String
    let createdAt: String
    let hasRecap: Bool
    let hasNotes: Bool
    let snippet: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "event_id"
        case title
        case durationSec = "duration_sec"
        case langStats = "lang_stats"
        case createdAt = "created_at"
        case hasRecap = "has_recap"
        case hasNotes = "has_notes"
        case snippet
    }

    // Explicit memberwise init: the synthesized one is internal by default,
    // which is fine within the module, but tests (Task 13) construct this
    // directly — keep it declared for clarity/stability across refactors.
    init(
        id: Int64, eventID: String?, title: String, durationSec: Int, langStats: String,
        createdAt: String, hasRecap: Bool, hasNotes: Bool, snippet: String
    ) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.durationSec = durationSec
        self.langStats = langStats
        self.createdAt = createdAt
        self.hasRecap = hasRecap
        self.hasNotes = hasNotes
        self.snippet = snippet
    }
}
