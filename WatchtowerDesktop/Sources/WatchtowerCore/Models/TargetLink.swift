import Foundation
import GRDB

// MARK: - TargetLink

package struct TargetLink: FetchableRecord, TableRecord, Codable, Identifiable, Equatable, Hashable {
    package static var databaseTableName = "target_links"

    package let id: Int
    package let sourceTargetId: Int
    package let targetTargetId: Int?    // nullable — link can be to an external ref instead
    package let externalRef: String     // e.g. 'jira:PROJ-123', 'slack:C123:1714567890.123456'
    package let relation: String        // "contributes_to", "blocks", "related", "duplicates"
    package let confidence: Double?     // AI-assigned, nil if user-created
    package let createdBy: String       // "ai", "user"
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case sourceTargetId  = "source_target_id"
        case targetTargetId  = "target_target_id"
        case externalRef     = "external_ref"
        case relation
        case confidence
        case createdBy       = "created_by"
        case createdAt       = "created_at"
    }

    package init(row: Row) {
        id             = row["id"]
        sourceTargetId = row["source_target_id"]
        targetTargetId = row["target_target_id"]
        externalRef    = row["external_ref"] ?? ""
        relation       = row["relation"] ?? ""
        confidence     = row["confidence"]
        createdBy      = row["created_by"] ?? "ai"
        createdAt      = row["created_at"] ?? ""
    }

    // MARK: - Hashable

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Helpers

    package var isAICreated: Bool { createdBy == "ai" }

    package var isExternalLink: Bool { !externalRef.isEmpty }
}
