import Foundation
import GRDB

// MARK: - Parent progress (dual path with Go)

/// A parent target's `progress` is the average of its non-dismissed children,
/// maintained on write. Go does it in `recomputeParentProgressOn`
/// (internal/db/targets.go); every Desktop writer that changes a child's
/// progress, status or parent calls the port below inside its own write
/// transaction. Both sides replay `internal/db/testdata/target_progress_cases.json`
/// (Go `TestRecomputeParentProgress_SharedFixture` ↔ Swift
/// `TargetProgressFixtureTests`) — change them together.
extension TargetQueries {

    /// Same cap as Go's `recomputeParentProgressMaxDepth`.
    static let recomputeParentProgressMaxDepth = 20

    /// Mirror of Go `statusToProgress`: a leaf's progress derived from its status.
    package static func statusProgress(_ status: String) -> Double {
        switch status {
        case "done": return 1.0
        case "in_progress": return 0.5
        case "blocked": return 0.2
        default: return 0.0 // todo, snoozed, dismissed
        }
    }

    /// Sets `parentID`'s progress to the average of its non-dismissed children
    /// (or, with none, to its own status's progress), then walks up the
    /// ancestor chain. A row is written — and its `updated_at` bumped — only
    /// when the computed value differs from the stored one (the next-step
    /// budget keys on `updated_at`). Cycles stop at the first revisited id;
    /// the walk is capped at 20 levels; both stops are logged, as in Go.
    /// Port of Go `recomputeParentProgressOn`.
    package static func recomputeParentProgress(_ db: Database, parentID: Int) throws {
        var visited = Set<Int>()
        var current = parentID

        for _ in 0..<recomputeParentProgressMaxDepth {
            if visited.contains(current) {
                NSLog("TargetQueries: recomputeParentProgress detected cycle at target %d — stopping", current)
                return
            }
            visited.insert(current)

            let avgRow = try Row.fetchOne(
                db,
                sql: "SELECT AVG(progress) FROM targets WHERE parent_id = ? AND status != 'dismissed'",
                arguments: [current]
            )
            let newProgress: Double
            if let avg = avgRow?[0] as Double? {
                newProgress = avg
            } else if let status = try String.fetchOne(
                db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [current]
            ) {
                newProgress = statusProgress(status)
            } else {
                newProgress = 0.0
            }

            try db.execute(
                sql: """
                    UPDATE targets SET progress = ?,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE id = ? AND progress != ?
                    """,
                arguments: [newProgress, current, newProgress]
            )

            let nextRow = try Row.fetchOne(
                db, sql: "SELECT parent_id FROM targets WHERE id = ?", arguments: [current]
            )
            guard let next = nextRow?["parent_id"] as Int? else { return }
            current = next
        }
        NSLog(
            "TargetQueries: recomputeParentProgress reached max depth (%d) at target %d — stopping",
            recomputeParentProgressMaxDepth, current
        )
    }

    /// The progress half of Go `UpdateTargetStatus`: a leaf (no non-dismissed
    /// children) takes its progress from the new status, then the parent
    /// chain is recomputed. Called after the status column itself is written.
    static func applyStatusProgress(_ db: Database, id: Int, status: String) throws {
        try db.execute(
            sql: """
                UPDATE targets SET progress = ? WHERE id = ? AND NOT EXISTS
                    (SELECT 1 FROM targets c WHERE c.parent_id = targets.id AND c.status != 'dismissed')
                """,
            arguments: [statusProgress(status), id]
        )
        try recomputeParentOf(db, id: id)
    }

    /// Recomputes the parent chain above `id`, if it has a parent.
    static func recomputeParentOf(_ db: Database, id: Int) throws {
        if let parentID = try parentID(db, of: id) {
            try recomputeParentProgress(db, parentID: parentID)
        }
    }

    static func parentID(_ db: Database, of id: Int) throws -> Int? {
        let row = try Row.fetchOne(db, sql: "SELECT parent_id FROM targets WHERE id = ?", arguments: [id])
        return row?["parent_id"] as Int?
    }

    /// Moves a target under `parentID` and recomputes both the old and the
    /// new parent chains (Go `UpdateTarget`'s reparent half, which also
    /// re-derives a leaf's own progress from its status). Refuses a parent on
    /// another board (`checkParentBoard`) before writing anything.
    package static func updateParent(_ db: Database, id: Int, parentID newParentID: Int) throws {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT status, project_id FROM targets WHERE id = ?", arguments: [id]
        ) else { return }
        let status: String = row["status"]
        try checkParentBoard(db, parentID: newParentID, childProjectID: row["project_id"])
        let oldParentID = try parentID(db, of: id)

        try db.execute(
            sql: """
                UPDATE targets SET parent_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [newParentID, id]
        )
        try applyStatusProgress(db, id: id, status: status)
        if let oldParentID, oldParentID != newParentID {
            try recomputeParentProgress(db, parentID: oldParentID)
        }
    }
}
