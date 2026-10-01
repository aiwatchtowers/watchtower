import Foundation
import GRDB

/// Why a cluster needs the owner: a match in the unsure band, no match at
/// all, an imported voice awaiting confirmation, two people too close to
/// call, or an explicit relabel request. Raw values = the
/// `voice_label_queue.reason` CHECK (migration 00080).
package enum VoiceLabelReason: String, Codable, Sendable {
    case unsure
    case unknown
    case importConfirm = "import_confirm"
    case conflict
    case relabel
}

package enum VoiceLabelTaskStatus: String, Codable, Sendable {
    case pending, done, skipped
}

/// One labeling task (`voice_label_queue`): a transcript's cluster the owner
/// should name. At most one pending task per transcript+cluster (partial
/// unique index).
package struct VoiceLabelTask: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Identifiable, Sendable {
    package static let databaseTableName = "voice_label_queue"

    package var id: Int64?
    package var transcriptID: Int64
    package var clusterLabel: String
    package var reason: VoiceLabelReason
    package var suggestedPersonID: Int64?
    package var score: Float?
    package var status: VoiceLabelTaskStatus
    package var createdAt: String
    package var resolvedAt: String?

    package init(
        id: Int64? = nil,
        transcriptID: Int64,
        clusterLabel: String,
        reason: VoiceLabelReason,
        suggestedPersonID: Int64? = nil,
        score: Float? = nil,
        status: VoiceLabelTaskStatus = .pending,
        createdAt: String = "",
        resolvedAt: String? = nil
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.clusterLabel = clusterLabel
        self.reason = reason
        self.suggestedPersonID = suggestedPersonID
        self.score = score
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case transcriptID = "transcript_id"
        case clusterLabel = "cluster_label"
        case reason
        case suggestedPersonID = "suggested_person_id"
        case score, status
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    /// An empty `createdAt` is left out of the INSERT so the column default stamps it.
    package func encode(to container: inout PersistenceContainer) throws {
        container[CodingKeys.id.rawValue] = id
        container[CodingKeys.transcriptID.rawValue] = transcriptID
        container[CodingKeys.clusterLabel.rawValue] = clusterLabel
        container[CodingKeys.reason.rawValue] = reason.rawValue
        container[CodingKeys.suggestedPersonID.rawValue] = suggestedPersonID
        container[CodingKeys.score.rawValue] = score
        container[CodingKeys.status.rawValue] = status.rawValue
        if !createdAt.isEmpty { container[CodingKeys.createdAt.rawValue] = createdAt }
        container[CodingKeys.resolvedAt.rawValue] = resolvedAt
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
