import Foundation
import GRDB

/// A user-editable watcher attached to an entity (v1: a target). Mirrors the Go
/// `observers` table. The daemon runs it over recent activity to produce events.
struct Observer: Codable, FetchableRecord, Identifiable, Equatable, Hashable {
    var id: Int
    var entityType: String
    var entityId: Int
    var name: String
    var instruction: String
    var enabled: Bool
    var lastRunAt: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case entityId = "entity_id"
        case name, instruction, enabled
        case lastRunAt = "last_run_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
