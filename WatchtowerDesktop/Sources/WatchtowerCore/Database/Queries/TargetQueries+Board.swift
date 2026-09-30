import Foundation
import GRDB

/// A parent and its child on different boards — the personal board
/// (`project_id` NULL) or a project's. Go twin: `db.ErrParentOtherBoard`
/// (`internal/db/targets_board.go`).
package struct TargetParentBoardError: LocalizedError, Equatable {
    package let parentID: Int
    package let parentProjectID: Int64?
    package let childProjectID: Int64?

    package var errorDescription: String? {
        "parent target #\(parentID) is on \(Self.boardName(parentProjectID)), "
            + "the child on \(Self.boardName(childProjectID)): a parent and its child must be on the same board"
    }

    private static func boardName(_ projectID: Int64?) -> String {
        projectID.map { "project \($0)'s board" } ?? "the personal board"
    }
}

extension TargetQueries {
    /// Refuses `parentID` when it is on a different board than a child on
    /// `childProjectID` (NULL vs N counts as different). A missing parent is
    /// left to the foreign key. Twin of Go `checkParentBoard`, which guards
    /// `CreateTarget`/`UpdateTarget` in `internal/db/targets.go` — every
    /// Swift writer of `targets.parent_id` calls this before writing.
    package static func checkParentBoard(_ db: Database, parentID: Int?, childProjectID: Int64?) throws {
        guard let parentID,
              let row = try Row.fetchOne(db, sql: "SELECT project_id FROM targets WHERE id = ?", arguments: [parentID])
        else { return }
        let parentProjectID: Int64? = row["project_id"]
        guard parentProjectID == childProjectID else {
            throw TargetParentBoardError(
                parentID: parentID, parentProjectID: parentProjectID, childProjectID: childProjectID
            )
        }
    }
}
