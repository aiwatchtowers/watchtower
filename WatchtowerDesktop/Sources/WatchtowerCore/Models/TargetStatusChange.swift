import Foundation
import GRDB

// MARK: - TargetStatusChange

/// One row of `target_status_history` (migration 00086, PROJ-06): a project
/// target moved from `fromStatus` (nil at creation) to `toStatus` at
/// `changedAt` (UTC ISO-8601), by `actor` — "agent", "owner" or "system".
/// Written only by the database's triggers; the Desktop only reads it.
package struct TargetStatusChange: FetchableRecord, TableRecord, Identifiable, Equatable, Hashable {
    package static var databaseTableName = "target_status_history"

    package let id: Int64
    package let targetID: Int64
    package let fromStatus: String?
    package let toStatus: String
    package let changedAt: String
    package let actor: String

    package init(row: Row) {
        id = row["id"]
        targetID = row["target_id"]
        fromStatus = row["from_status"]
        toStatus = row["to_status"] ?? ""
        changedAt = row["changed_at"] ?? ""
        actor = row["actor"] ?? ""
    }
}

// MARK: - Queries

extension TargetQueries {
    /// Same cap as Go `db.MaxStatusHistory`.
    package static let maxStatusHistory = 50

    /// Target `targetID`'s newest status changes, oldest first (Go
    /// `GetTargetStatusHistory`). A personal target has none.
    package static func statusHistory(_ db: Database, targetID: Int64, limit: Int = maxStatusHistory) throws -> [TargetStatusChange] {
        let capped = limit <= 0 ? maxStatusHistory : min(limit, maxStatusHistory)
        let newest = try TargetStatusChange.fetchAll(
            db,
            sql: "SELECT * FROM target_status_history WHERE target_id = ? ORDER BY id DESC LIMIT ?",
            arguments: [targetID, capped]
        )
        return newest.reversed()
    }
}
