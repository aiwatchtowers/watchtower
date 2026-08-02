import Foundation

/// One RoleAssigner merge unit of a transcript — consecutive same-speaker
/// transcription segments merged into a single utterance with a time range.
/// Persisted as a JSON array in `meeting_transcripts.segments_json`
/// (snake_case keys, shared shape with Go's
/// `internal/meeting.TranscriptUtterance`). `deleted` is the soft-delete
/// flag: a deleted utterance stays in the array (no hard deletion) but is
/// excluded from the rendered transcript text.
struct TranscriptUtterance: Codable, Equatable, Sendable, Identifiable {
    let idx: Int
    let startSec: Double
    let endSec: Double
    let speaker: String
    let text: String
    var deleted: Bool

    var id: Int { idx }

    enum CodingKeys: String, CodingKey {
        case idx
        case startSec = "start_sec"
        case endSec = "end_sec"
        case speaker
        case text
        case deleted
    }

    init(idx: Int, startSec: Double, endSec: Double, speaker: String, text: String, deleted: Bool = false) {
        self.idx = idx
        self.startSec = startSec
        self.endSec = endSec
        self.speaker = speaker
        self.text = text
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idx = try container.decode(Int.self, forKey: .idx)
        startSec = try container.decode(Double.self, forKey: .startSec)
        endSec = try container.decode(Double.self, forKey: .endSec)
        speaker = try container.decode(String.self, forKey: .speaker)
        text = try container.decode(String.self, forKey: .text)
        // Absent flag reads as not-deleted, mirroring Go's zero-value decode.
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// Canonical Swift renderer + codec for the `segments_json` payload.
enum TranscriptSegments {
    /// Canonical renderer for the load-bearing invariant
    /// `transcript_text = render(segments where !deleted)`: one
    /// "[speaker] text" line per non-deleted utterance, newline-joined.
    /// MUST stay behaviorally identical to Go's
    /// `internal/meeting.RenderTranscriptSegments` (the CLI-save writer;
    /// this one covers UI edits) — a deliberate dual-path like `saveNotes`,
    /// pinned by matching fixtures in `segments_test.go` and
    /// `TranscriptUtteranceTests.swift`.
    static func render(_ utterances: [TranscriptUtterance]) -> String {
        utterances.filter { !$0.deleted }
            .map { "[\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")
    }

    /// Deterministic encoding (sorted keys) so a delete → undo cycle restores
    /// the stored JSON byte-identically.
    static func encode(_ utterances: [TranscriptUtterance]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(utterances) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil for malformed JSON or an empty array — callers then fall back to
    /// the flat transcript text (legacy behavior).
    static func decode(_ json: String) -> [TranscriptUtterance]? {
        guard let data = json.data(using: .utf8),
              let utterances = try? JSONDecoder().decode([TranscriptUtterance].self, from: data),
              !utterances.isEmpty else {
            return nil
        }
        return utterances
    }
}
