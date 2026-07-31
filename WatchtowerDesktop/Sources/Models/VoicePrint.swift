import Foundation
import GRDB

/// One known person's voice: the L2-normalized centroid of every confirmed
/// cluster embedding for that person, learned exclusively from manual speaker
/// renames in the transcript view (never auto-created by matching alone).
/// `personKey` is the attendee email, or a normalized display name when no
/// email is known. `embedding` stores 256 little-endian float32 values in a
/// BLOB. Local-only data — never synced or exported.
struct VoicePrint: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "voice_prints"

    var id: Int64?
    let personKey: String
    let displayName: String
    let embedding: Data
    let sampleCount: Int
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case personKey = "person_key"
        case displayName = "display_name"
        case embedding
        case sampleCount = "sample_count"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decoded centroid vector; empty for a corrupt/odd-length BLOB (callers
    /// skip such prints when matching).
    var embeddingVector: [Float] {
        VoicePrintEmbedding.decode(embedding)
    }
}

/// BLOB codec for voice-print embeddings: little-endian float32, no header.
enum VoicePrintEmbedding {
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// One diarized cluster's voice embedding for a saved recording, keyed by the
/// FINAL rendered speaker label ("Я", "Speaker N", or a matched display
/// name). Persisted as a JSON array in `meeting_transcripts.speakers_json`
/// (snake_case keys, shared shape with Go's
/// `internal/meeting.SpeakerEmbedding`). Labels are rewritten on rename so a
/// later rename of the same cluster still resolves its embedding.
struct SpeakerEmbedding: Codable, Equatable, Sendable {
    var speaker: String
    let embedding: [Float]
}

/// Naming helpers shared by the rename picker and the suggestion chips.
enum SpeakerNaming {
    /// True for the default label of a cluster nobody has named yet
    /// ("Speaker 1", "Speaker 2", …) — the only labels the LLM guess targets.
    /// Dual-path with Go's `speakerNumberRe` (internal/meeting/speaker_guess.go)
    /// — the two regexes MUST stay identical (transcriber dual-path convention).
    static func isUnnamed(_ label: String) -> Bool {
        label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// True when a name collides with a reserved label: the owner's «Я» (any
    /// case) or the unnamed "Speaker N" pattern. Renaming a cluster to a
    /// reserved label would merge a stranger into the owner's identity (and
    /// mint a voice print whose embedding voice-matches that stranger to «Я»
    /// in every future recording) or fake an unnamed cluster — rejected in
    /// both the rename sheet and `MeetingTranscriptQueries.renameSpeaker`,
    /// mirroring Go's `reservedSpeakerLabel` (internal/meeting/speaker_guess.go).
    static func isReserved(_ label: String) -> Bool {
        label.caseInsensitiveCompare("Я") == .orderedSame || isUnnamed(label)
    }

    /// Derives the `voice_prints.person_key` for a confirmed display name:
    /// the attendee's email (lowercased) when the name matches an event
    /// attendee by display name or email (case-insensitive), else the
    /// normalized (trimmed, lowercased) name itself.
    static func personKey(for name: String, attendees: [EventAttendee]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = attendees.first(where: {
            (!$0.displayName.isEmpty && $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame)
                || (!$0.email.isEmpty && $0.email.caseInsensitiveCompare(trimmed) == .orderedSame)
        }), !match.email.isEmpty {
            return match.email.lowercased()
        }
        return trimmed.lowercased()
    }
}

/// Canonical Swift codec for the `speakers_json` payload.
enum SpeakerEmbeddings {
    /// Deterministic encoding (sorted keys), mirroring TranscriptSegments.
    static func encode(_ speakers: [SpeakerEmbedding]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(speakers) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil for malformed JSON or an empty array — callers then behave as if
    /// the recording carried no embeddings (transcript-only rename).
    static func decode(_ json: String) -> [SpeakerEmbedding]? {
        guard let data = json.data(using: .utf8),
              let speakers = try? JSONDecoder().decode([SpeakerEmbedding].self, from: data),
              !speakers.isEmpty else {
            return nil
        }
        return speakers
    }
}
