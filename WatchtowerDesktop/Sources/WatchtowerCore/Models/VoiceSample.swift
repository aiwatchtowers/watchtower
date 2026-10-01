import Foundation
import GRDB

/// Where a voice sample came from: an owner confirmation (the only origin an
/// anchor may have), the self-training rule, or a colleague's import file.
package enum VoiceSampleOrigin: String, Codable, Sendable {
    case owner, auto, imported
}

/// `pending` = an imported sample awaiting the owner's confirmation (it can
/// only suggest, never name); `retired` = kept for history, never matched.
package enum VoiceSampleStatus: String, Codable, Sendable {
    case active, pending, retired
}

/// Which capture path a cluster's voice came through: the owner's mic (a
/// meeting room), the system audio (a remote participant), or undecidable.
package enum VoiceChannel: String, Codable, Sendable {
    case room, remote, unknown
}

/// One voice sample of a registry person (`voice_samples`, migration 00080).
/// `embedding` stores little-endian float32 values (`VoicePrintEmbedding`).
package struct VoiceSample: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Identifiable, Sendable {
    package static let databaseTableName = "voice_samples"

    package var id: Int64?
    package var personID: Int64
    package var embedding: Data
    package var modelVersion: String
    package var origin: VoiceSampleOrigin
    package var anchor: Bool
    package var status: VoiceSampleStatus
    package var transcriptID: Int64?
    package var clusterLabel: String?
    package var channel: VoiceChannel
    package var score: Float?
    package var speechSec: Double
    package var importID: Int64?
    /// nil before insert — the column default stamps it.
    package var createdAt: String?

    package init(
        id: Int64? = nil,
        personID: Int64,
        embedding: Data,
        modelVersion: String,
        origin: VoiceSampleOrigin,
        anchor: Bool,
        status: VoiceSampleStatus,
        transcriptID: Int64? = nil,
        clusterLabel: String? = nil,
        channel: VoiceChannel = .unknown,
        score: Float? = nil,
        speechSec: Double = 0,
        importID: Int64? = nil
    ) {
        self.id = id
        self.personID = personID
        self.embedding = embedding
        self.modelVersion = modelVersion
        self.origin = origin
        self.anchor = anchor
        self.status = status
        self.transcriptID = transcriptID
        self.clusterLabel = clusterLabel
        self.channel = channel
        self.score = score
        self.speechSec = speechSec
        self.importID = importID
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case personID = "person_id"
        case embedding
        case modelVersion = "model_version"
        case origin, anchor, status
        case transcriptID = "transcript_id"
        case clusterLabel = "cluster_label"
        case channel, score
        case speechSec = "speech_sec"
        case importID = "import_id"
        case createdAt = "created_at"
    }

    /// A nil `createdAt` is left out of the INSERT so the column default
    /// stamps it (an explicit NULL would violate NOT NULL).
    package func encode(to container: inout PersistenceContainer) throws {
        container[CodingKeys.id.rawValue] = id
        container[CodingKeys.personID.rawValue] = personID
        container[CodingKeys.embedding.rawValue] = embedding
        container[CodingKeys.modelVersion.rawValue] = modelVersion
        container[CodingKeys.origin.rawValue] = origin.rawValue
        container[CodingKeys.anchor.rawValue] = anchor
        container[CodingKeys.status.rawValue] = status.rawValue
        container[CodingKeys.transcriptID.rawValue] = transcriptID
        container[CodingKeys.clusterLabel.rawValue] = clusterLabel
        container[CodingKeys.channel.rawValue] = channel.rawValue
        container[CodingKeys.score.rawValue] = score
        container[CodingKeys.speechSec.rawValue] = speechSec
        container[CodingKeys.importID.rawValue] = importID
        if let createdAt { container[CodingKeys.createdAt.rawValue] = createdAt }
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decoded, L2-normalized vector; empty for a corrupt BLOB (never matches).
    package var vector: [Float] {
        VoiceMatcher.normalize(VoicePrintEmbedding.decode(embedding)) ?? []
    }
}
