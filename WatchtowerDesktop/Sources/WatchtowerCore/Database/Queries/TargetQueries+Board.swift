import Foundation
import GRDB

/// A parent and its child on different boards — the personal board
/// (`project_id` NULL) or a project's. Go twin: `db.ErrParentOtherBoard`
/// (`internal/db/targets_board.go`).
package struct TargetParentBoardError: LocalizedError, Equatable {
    package let parentID: Int
    package let parentWorkbenchID: Int64?
    package let childWorkbenchID: Int64?

    package var errorDescription: String? {
        "parent target #\(parentID) is on \(Self.boardName(parentWorkbenchID)), "
            + "the child on \(Self.boardName(childWorkbenchID)): a parent and its child must be on the same board"
    }

    private static func boardName(_ projectID: Int64?) -> String {
        projectID.map { "workbench \($0)'s board" } ?? "the personal board"
    }
}

/// A new parent that is the target itself or one of its sub-targets (board
/// #186, PROJ-09). Go twin: `db.ErrParentCycle`.
package struct TargetParentCycleError: LocalizedError, Equatable {
    package let id: Int64
    package let parentID: Int64

    package init(id: Int64, parentID: Int64) {
        self.id = id
        self.parentID = parentID
    }

    package var errorDescription: String? {
        "target #\(id) cannot move under #\(parentID): a target cannot be nested under itself or its own sub-target"
    }
}

extension TargetQueries {
    /// Refuses `parentID` when it is `id` itself or one of its descendants: it
    /// walks up from `parentID` by id, and UNION drops an id already seen, so
    /// a row already in a cycle ends the walk too. Twin of Go
    /// `checkParentCycle` (`internal/db/targets_board.go`).
    package static func checkParentCycle(_ db: Database, id: Int64, parentID: Int64?) throws {
        guard let parentID else { return }
        let cycle = try Bool.fetchOne(db, sql: """
            WITH RECURSIVE up(id) AS (
                SELECT ?
                UNION
                SELECT t.parent_id FROM targets t JOIN up ON t.id = up.id WHERE t.parent_id IS NOT NULL
            )
            SELECT EXISTS (SELECT 1 FROM up WHERE id = ?)
            """, arguments: [parentID, id])
        // EXISTS always yields a row; a missing one refuses rather than risk a cycle.
        if cycle ?? true { throw TargetParentCycleError(id: id, parentID: parentID) }
    }

    /// Refuses `parentID` when it is on a different board than a child on
    /// `childWorkbenchID` (NULL vs N counts as different), and a parent that no
    /// longer exists with `TargetNotFoundError` naming it — the foreign key
    /// would refuse it too, but as a bare "FOREIGN KEY constraint failed".
    /// Twin of Go `checkParentBoard`, which guards `CreateTarget`/`UpdateTarget`
    /// in `internal/db/targets.go` (Go still leaves a missing parent to the
    /// foreign key) — every Swift writer of `targets.parent_id` calls this
    /// before writing.
    package static func checkParentBoard(_ db: Database, parentID: Int?, childWorkbenchID: Int64?) throws {
        guard let parentID else { return }
        guard let row = try Row.fetchOne(
            db, sql: "SELECT project_id FROM targets WHERE id = ?", arguments: [parentID]
        ) else { throw TargetNotFoundError(id: parentID) }
        let parentWorkbenchID: Int64? = row["project_id"]
        guard parentWorkbenchID == childWorkbenchID else {
            throw TargetParentBoardError(
                parentID: parentID, parentWorkbenchID: parentWorkbenchID, childWorkbenchID: childWorkbenchID
            )
        }
    }
}
