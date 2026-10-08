import Foundation
import GRDB

// MARK: - MeetingTranscript

/// One locally-recorded meeting — the mobile mirror of the desktop's
/// `meeting_transcripts` row (see `MeetingRecorderCenter` and the transcriber
/// stack on that side).
///
/// Unlike every other slice this one is published as a PROJECTION, so the model
/// deliberately has NO `transcriptText`: the full text (and `segments_json`)
/// would dominate the record and stays on the Mac, reachable through the
/// desktop app. `snippet` is the first 200 characters, mirroring the desktop
/// recordings list's own perf projection.
///
/// `recapJSON` is the RESOLVED recap the publisher computes in SQL — the linked
/// event's `meeting_recaps` row when it has one, the recording's own
/// `summary_json` otherwise (the desktop's `RecordingDetailView.load` rule).
/// `speakers` is the diarized speaker roster (labels only; the voice embeddings
/// never leave the Mac).
public struct MeetingTranscript: FetchableRecord, Identifiable, Equatable {
    public let id: Int
    /// nil for an ad-hoc recording — one that was never linked to an event, or
    /// whose event was deleted (the column is ON DELETE SET NULL: a transcript
    /// outlives its calendar event).
    public let eventID: String?         // column: event_id
    /// Title of the linked calendar event (publisher LEFT JOIN); nil for an
    /// ad-hoc recording and for a link whose event row sync retention pruned.
    public let eventTitle: String?      // column: event_title
    public let title: String
    public let durationSec: Int         // column: duration_sec
    public let langStats: String        // column: lang_stats
    public let notesMD: String          // column: notes_md
    public let chaptersJSON: String     // column: chapters_json
    public let recapJSON: String        // column: recap_json (publisher-resolved)
    public let speakers: String         // column: speakers (publisher-joined JSON array)
    /// First 200 characters of the transcript — the whole text is not synced.
    public let snippet: String
    public let createdAt: String
    public let updatedAt: String

    public init(row: Row) {
        id = row["id"]
        eventID = row["event_id"]
        eventTitle = row["event_title"]
        title = row["title"] ?? ""
        durationSec = row["duration_sec"] ?? 0
        langStats = row["lang_stats"] ?? ""
        notesMD = row["notes_md"] ?? ""
        chaptersJSON = row["chapters_json"] ?? ""
        recapJSON = row["recap_json"] ?? ""
        speakers = row["speakers"] ?? "[]"
        snippet = row["snippet"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    // MARK: - Recap

    /// The recap shape the meeting pipeline produces — the mobile mirror of the
    /// desktop's `MeetingRecap.Content`. Absent keys default instead of failing
    /// the decode, matching Go's `json.Unmarshal` tolerance in
    /// `internal/mcp/transcripts.go` (a partial recap still carries its
    /// summary).
    public struct Recap: Decodable, Equatable {
        public let summary: String
        public let keyDecisions: [String]
        public let actionItems: [String]
        public let openQuestions: [String]

        enum CodingKeys: String, CodingKey {
            case summary
            case keyDecisions = "key_decisions"
            case actionItems = "action_items"
            case openQuestions = "open_questions"
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
            keyDecisions = try values.decodeIfPresent([String].self, forKey: .keyDecisions) ?? []
            actionItems = try values.decodeIfPresent([String].self, forKey: .actionItems) ?? []
            openQuestions = try values.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        }
    }

    /// The resolved recap, or nil when the recording has none (or the stored
    /// JSON is unreadable — a bad recap must never hide the recording).
    public var recap: Recap? {
        guard !recapJSON.isEmpty, let data = recapJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Recap.self, from: data)
    }

    // MARK: - Speakers

    /// Diarized speaker labels ("Я", "Speaker 2", a confirmed name) from the
    /// publisher-joined `speakers` array; empty when the recording was not
    /// diarized.
    public var decodedSpeakers: [String] {
        guard !speakers.isEmpty, speakers != "[]",
              let data = speakers.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
