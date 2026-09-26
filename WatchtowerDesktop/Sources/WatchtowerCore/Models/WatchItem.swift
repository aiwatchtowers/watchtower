import GRDB

package struct WatchItem: FetchableRecord, Decodable, Identifiable, Equatable {
    package let entityType: String
    package let entityID: String
    package let entityName: String?
    package let priority: String
    package let createdAt: String?

    package var id: String { "\(entityType)_\(entityID)" }

    package enum CodingKeys: String, CodingKey {
        case priority
        case entityType = "entity_type"
        case entityID = "entity_id"
        case entityName = "entity_name"
        case createdAt = "created_at"
    }
}
