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

extension TargetQueries {
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
