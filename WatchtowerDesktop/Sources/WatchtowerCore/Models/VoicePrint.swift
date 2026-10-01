import Foundation
import GRDB

/// One known person in the voice registry (migration 00080): identity only —
/// the voice itself lives as per-sample rows in `voice_samples`
/// (`VoiceSample`), matched nearest-sample rather than as one averaged
/// centroid. `personKey` is the attendee email, or a normalized display name
/// when no email is known. Local-only data; exported only by an explicit
/// owner action.
package struct VoicePrint: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Identifiable, Sendable {
    package static let databaseTableName = "voice_prints"

    package var id: Int64?
    package let personKey: String
    package var displayName: String
    package var createdAt: String
    package var updatedAt: String

    package init(
        id: Int64? = nil,
        personKey: String,
        displayName: String,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.personKey = personKey
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case personKey = "person_key"
        case displayName = "display_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Empty timestamps (a fresh in-memory row) are left out of the INSERT
    /// so the column defaults stamp them.
    package func encode(to container: inout PersistenceContainer) throws {
        container[CodingKeys.id.rawValue] = id
        container[CodingKeys.personKey.rawValue] = personKey
        container[CodingKeys.displayName.rawValue] = displayName
        if !createdAt.isEmpty { container[CodingKeys.createdAt.rawValue] = createdAt }
        if !updatedAt.isEmpty { container[CodingKeys.updatedAt.rawValue] = updatedAt }
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Who set a cluster's current label: the owner (a manual label, or the «Я»
/// role pass), the registry's automatic match, or nobody (an unnamed
/// "Speaker N").
package enum VoiceLabelSource: String, Codable, Sendable {
    case owner, auto, none
}

/// A clip of one cluster's clean speech (absolute seconds in the recording),
/// used to play a voice back when the owner labels it.
package struct ClipSpan: Codable, Equatable, Sendable {
    package let start: Double
    package let end: Double

    package init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// BLOB codec for voice-print embeddings: little-endian float32, no header.
package enum VoicePrintEmbedding {
    package static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    package static func decode(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// One diarized cluster's voice embedding for a saved recording, keyed by the
/// FINAL rendered speaker label ("Я", "Speaker N", or a matched display
/// name). Persisted as a JSON array in `meeting_transcripts.speakers_json`
/// (snake_case keys; Go's `transcript save` stores each entry's raw JSON
/// verbatim, so the registry fields below round-trip untouched). Labels are
/// rewritten on relabel so a later relabel of the same cluster still resolves
/// its embedding. Every registry field is optional: legacy rows carry only
/// `speaker` + `embedding`.
package struct SpeakerEmbedding: Codable, Equatable, Sendable {
    package var speaker: String
    package let embedding: [Float]
    /// The "Speaker N" label the cluster had before any name was applied.
    package var originalLabel: String?
    /// `voice_prints.id` of the person the label names, when known.
    package var personID: Int64?
    package var labelSource: VoiceLabelSource?
    /// Cosine score of the automatic match (auto labels only).
    package var score: Float?
    /// `voice_samples.id` of the sample that won the automatic match.
    package var matchedSampleID: Int64?
    package var channel: VoiceChannel?
    package var clips: [ClipSpan]?
    package var speechSec: Double?
    /// Embedding model that produced `embedding` (`VoiceRegistryPolicy.embeddingModelVersion`).
    package var modelVersion: String?
    /// Set by "Several people" (spec §3.1 dismiss): the cluster mixed more
    /// than one voice and must never be learned from or relabeled again
    /// (Task 9 retro skips `mixed == true`).
    package var mixed: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// People the owner said this cluster is NOT (a rejected auto label, or
    /// a relabel away from a wrong name): no automatic path may assign them
    /// to it again. Cleared per person when the owner names the cluster as
    /// that person by hand.
    package var rejectedPersonIDs: [Int64]?

    package init(speaker: String, embedding: [Float]) {
        self.speaker = speaker
        self.embedding = embedding
    }

    package enum CodingKeys: String, CodingKey {
        case speaker, embedding
        case originalLabel = "original_label"
        case personID = "person_id"
        case labelSource = "label_source"
        case score
        case matchedSampleID = "matched_sample_id"
        case channel, clips
        case speechSec = "speech_sec"
        case modelVersion = "model_version"
        case mixed
        case rejectedPersonIDs = "rejected_person_ids"
    }

    /// Legacy rows carry no label_source: an unnamed "Speaker N" is `none`,
    /// anything else (a name, «Я») was set by the owner or the role pass and
    /// retro relabel must never touch it (spec §1.7, invariant 5).
    package var effectiveLabelSource: VoiceLabelSource {
        labelSource ?? (SpeakerNaming.isUnnamed(speaker) ? .none : .owner)
    }

    /// The label retro/rollback restores; legacy rows fall back to the current label.
    package var restoreLabel: String { originalLabel ?? speaker }

    /// Records the owner's verdict that this cluster is not `personID`.
    package mutating func rejectPerson(_ personID: Int64) {
        var ids = rejectedPersonIDs ?? []
        if !ids.contains(personID) { ids.append(personID) }
        rejectedPersonIDs = ids
    }

    /// Lifts a rejection of `personID` (the owner named the cluster as them
    /// by hand); an empty list goes back to absent.
    package mutating func clearRejection(of personID: Int64) {
        let ids = (rejectedPersonIDs ?? []).filter { $0 != personID }
        rejectedPersonIDs = ids.isEmpty ? nil : ids
    }
}

/// Naming helpers shared by the rename picker and the suggestion chips.
package enum SpeakerNaming {
    /// True for the default label of a cluster nobody has named yet
    /// ("Speaker 1", "Speaker 2", …) — the only labels the LLM guess targets.
    package static func isUnnamed(_ label: String) -> Bool {
        label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// True when a name collides with a reserved label: the owner's «Я» (any
    /// case) or the unnamed "Speaker N" pattern. Renaming a cluster to a
    /// reserved label would merge a stranger into the owner's identity (and
    /// mint a voice print whose embedding voice-matches that stranger to «Я»
    /// in every future recording) or fake an unnamed cluster — rejected by
    /// the rename sheet. `MeetingTranscriptQueries.relabelCluster` rejects
    /// only «Я» (a rollback legitimately restores "Speaker N").
    package static func isReserved(_ label: String) -> Bool {
        label.caseInsensitiveCompare("Я") == .orderedSame || isUnnamed(label)
    }

    /// Derives the `voice_prints.person_key` for a confirmed display name:
    /// the attendee's email (lowercased) when the name matches an event
    /// attendee by display name or email (case-insensitive), else the
    /// normalized (trimmed, lowercased) name itself.
    package static func personKey(for name: String, attendees: [EventAttendee]) -> String {
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
package enum SpeakerEmbeddings {
    /// Deterministic encoding (sorted keys), mirroring TranscriptSegments.
    package static func encode(_ speakers: [SpeakerEmbedding]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(speakers) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil for malformed JSON or an empty array — callers then behave as if
    /// the recording carried no embeddings (transcript-only rename).
    package static func decode(_ json: String) -> [SpeakerEmbedding]? {
        guard let data = json.data(using: .utf8),
              let speakers = try? JSONDecoder().decode([SpeakerEmbedding].self, from: data),
              !speakers.isEmpty else {
            return nil
        }
        return speakers
    }
}
