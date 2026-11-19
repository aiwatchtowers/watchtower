import Foundation
import GRDB
import WatchtowerInterface

/// What one owner board write changed (mobile POC spec §6.3): the target it
/// named and the parents the PROJ-05 rollup moved in the same write. Both
/// are the owner's doing, so the caller reports every one of them to
/// `onOwnerWrite` and the Mac never notifies the owner about their own edit.
package struct WorkbenchOwnerWrite: Equatable, Sendable {
    /// The target the write named (a reply's: its thread's).
    package let target: Int64
    /// The ancestors whose status the rollup moved, in id order.
    package let rolledUp: [Int64]

    /// Every target to report, the named one first.
    package var touched: [Int64] { [target] + rolledUp }

    package init(target: Int64, rolledUp: [Int64]) {
        self.target = target
        self.rolledUp = rolledUp
    }

    /// A status or card move Go wrote on `target` (`targets.set_status` /
    /// `targets.set_column`): the parents its rollup moved are Go's `rolled_up`.
    package init(_ result: TargetStatusResult, target: Int64) {
        self.init(target: target, rolledUp: result.rolledUp.sorted())
    }
}

/// The owner's board writes the Desktop still makes in Swift. A status or a
/// card move is Go's (`targets.set_status` / `targets.set_column`, #1170
/// Task 12). Each runs inside the caller's write transaction; the caller
/// decides what may be written (the board's guards).
package enum WorkbenchOwnerWrites {
    package static func setPriority(_ db: Database, targetID: Int64, priority: String) throws -> WorkbenchOwnerWrite {
        try TargetQueries.updatePriority(db, id: Int(targetID), priority: priority)
        return WorkbenchOwnerWrite(target: targetID, rolledUp: [])
    }

    /// The folder a target's work is in (nil = the home folder).
    package static func setFolder(_ db: Database, targetID: Int64, folderID: Int64?) throws -> WorkbenchOwnerWrite {
        try TargetQueries.setFolder(db, targetID: Int(targetID), folderID: folderID)
        return WorkbenchOwnerWrite(target: targetID, rolledUp: [])
    }

    /// A new owner thread on a target of `projectID`.
    package static func addComment(
        _ db: Database, projectID: Int64, targetID: Int64, body: String
    ) throws -> (commentID: Int64, write: WorkbenchOwnerWrite) {
        let id = try WorkbenchQueries.addOwnerComment(db, projectID: projectID, targetID: targetID, body: body)
        return (id, WorkbenchOwnerWrite(target: targetID, rolledUp: []))
    }

    /// An owner reply under `rootID`; a resolved or outdated root reopens
    /// (`WorkbenchQueries.reply`).
    package static func reply(
        _ db: Database, to rootID: Int64, body: String
    ) throws -> (commentID: Int64, write: WorkbenchOwnerWrite) {
        let id = try WorkbenchQueries.reply(db, to: rootID, body: body)
        // The reply inherits its root's target, which every root has (the
        // table's CHECK).
        let target = try Int64.fetchOne(db, sql: "SELECT target_id FROM project_comments WHERE id = ?", arguments: [id])
        guard let target else { throw RowNotFoundError(kind: "comment target", id: id) }
        return (id, WorkbenchOwnerWrite(target: target, rolledUp: []))
    }
}
