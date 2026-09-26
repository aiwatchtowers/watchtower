import Foundation
import GRDB

/// Lightweight projection of `meeting_transcripts` for the Recordings master
/// list. Deliberately excludes `transcript_text` (only a 200-char snippet) and
/// `summary_json` (only a boolean) so scrolling the list never deserializes
/// megabyte blobs — mirroring the Go `transcript list` command.
package struct RecordingListItem: Decodable, FetchableRecord, Identifiable, Equatable {
    package let id: Int64
    package let eventID: String?
    /// Title of the linked calendar event (LEFT JOIN in `fetchRecordingList`);
    /// nil for ad-hoc recordings and for links whose event row was pruned by
    /// sync retention.
    package let eventTitle: String?
    package let title: String
    package let durationSec: Int
    package let langStats: String
    package let createdAt: String
    package let hasRecap: Bool
    package let hasNotes: Bool
    package let snippet: String

    package init(
        id: Int64,
        eventID: String?,
        eventTitle: String?,
        title: String,
        durationSec: Int,
        langStats: String,
        createdAt: String,
        hasRecap: Bool,
        hasNotes: Bool,
        snippet: String
    ) {
        self.id = id
        self.eventID = eventID
        self.eventTitle = eventTitle
        self.title = title
        self.durationSec = durationSec
        self.langStats = langStats
        self.createdAt = createdAt
        self.hasRecap = hasRecap
        self.hasNotes = hasNotes
        self.snippet = snippet
    }

    package enum CodingKeys: String, CodingKey {
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
    package var createdDate: Date? {
        Self.iso8601Formatter.date(from: createdAt)
    }
}
