import Foundation
import GRDB

/// Lightweight projection of `meeting_transcripts` for the Recordings master
/// list. Deliberately excludes `transcript_text` (only a 200-char snippet) and
/// `summary_json` (only a boolean) so scrolling the list never deserializes
/// megabyte blobs — mirroring the Go `transcript list` command.
struct RecordingListItem: Decodable, FetchableRecord, Identifiable, Equatable {
    let id: Int64
    let eventID: String?
    /// Title of the linked calendar event (LEFT JOIN in `fetchRecordingList`);
    /// nil for ad-hoc recordings and for links whose event row was pruned by
    /// sync retention.
    let eventTitle: String?
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
        case eventTitle = "event_title"
        case title
        case durationSec = "duration_sec"
        case langStats = "lang_stats"
        case createdAt = "created_at"
        case hasRecap = "has_recap"
        case hasNotes = "has_notes"
        case snippet
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// Parses `createdAt` (`strftime('%Y-%m-%dT%H:%M:%SZ','now')` from the
    /// CLI) into a `Date`; nil for malformed input.
    var createdDate: Date? {
        Self.iso8601Formatter.date(from: createdAt)
    }
}
