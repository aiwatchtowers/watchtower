import Foundation
import GRDB

package struct InboxLearnedRule: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    package static let databaseTableName = "inbox_learned_rules"

    package var id: Int64?
    package var ruleType: String
    package var scopeKey: String
    package var weight: Double
    package var source: String
    package var evidenceCount: Int
    package var lastUpdated: String

    package init(
        id: Int64? = nil,
        ruleType: String,
        scopeKey: String,
        weight: Double,
        source: String,
        evidenceCount: Int,
        lastUpdated: String
    ) {
        self.id = id
        self.ruleType = ruleType
        self.scopeKey = scopeKey
        self.weight = weight
        self.source = source
        self.evidenceCount = evidenceCount
        self.lastUpdated = lastUpdated
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case ruleType = "rule_type"
        case scopeKey = "scope_key"
        case weight
        case source
        case evidenceCount = "evidence_count"
        case lastUpdated = "last_updated"
    }
}
