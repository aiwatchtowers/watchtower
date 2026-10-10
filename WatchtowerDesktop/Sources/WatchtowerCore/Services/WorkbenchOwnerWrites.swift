import Foundation
import GRDB

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
}

/// The owner's board writes, shared by the Desktop board
/// (`WorkbenchBoardViewModel`) and the mobile hub's board handlers, so a
/// phone edit runs the very code a Desktop edit runs (spec §6.3, I-2). Each
/// runs inside the caller's write transaction; the caller decides what may
/// be written (the board's guards, the hub's stale-view and scope checks).
package enum WorkbenchOwnerWrites {
    /// A status claimed by the owner (`TargetQueries.updateStatus`, PROJ-06),
    /// with the parents the rollup moved (PROJ-05).
    package static func setStatus(_ db: Database, targetID: Int64, status: String) throws -> WorkbenchOwnerWrite {
        let before = try WorkbenchQueries.ancestorStatuses(db, of: targetID)
        try TargetQueries.updateStatus(db, id: Int(targetID), status: status)
        let after = try WorkbenchQueries.ancestorStatuses(db, of: targetID)
        let rolledUp = after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
        return WorkbenchOwnerWrite(target: targetID, rolledUp: rolledUp)
    }

    package static func setPriority(_ db: Database, targetID: Int64, priority: String) throws -> WorkbenchOwnerWrite {
        try TargetQueries.updatePriority(db, id: Int(targetID), priority: priority)
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
