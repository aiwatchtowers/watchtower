import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The owner's board writes shared by the Desktop board and the mobile hub
/// (mobile POC spec §6.3): each write and the ids it reports.
final class WorkbenchOwnerWritesTests: XCTestCase {
    private func status(_ db: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [id])
    }

    private func lastActor(_ db: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(
            db, sql: "SELECT actor FROM target_status_history WHERE target_id = ? ORDER BY id DESC LIMIT 1", arguments: [id]
        )
    }

    /// PROJ-05/06: the named target's change is the owner's in its history,
    /// and the parents the rollup closed in the same write come back too.
    func testSetStatusClaimsTheOwnerAndReturnsTheRolledUpParents() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Plan")
            let mid = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Feature", parentID: root)
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task", parentID: mid)

            let write = try WorkbenchOwnerWrites.setStatus(db, targetID: leaf, status: "done")

            XCTAssertEqual(write, WorkbenchOwnerWrite(target: leaf, rolledUp: [root, mid].sorted()))
            XCTAssertEqual(write.touched, [leaf] + [root, mid].sorted())
            XCTAssertEqual(try status(db, leaf), "done")
            XCTAssertEqual(try status(db, root), "done", "PROJ-05: the chain rolls up")
            XCTAssertEqual(try lastActor(db, leaf), "owner", "PROJ-06: the owner's change")
            XCTAssertEqual(try lastActor(db, mid), "system", "the rollup's own change")
        }
    }

    func testSetStatusOnAnUnchangedChainReportsOnlyTheTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Plan")
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress", parentID: root)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress", parentID: root)

            let write = try WorkbenchOwnerWrites.setStatus(db, targetID: leaf, status: "in_review")

            XCTAssertEqual(write.touched, [leaf], "the parent stays in_progress")
        }
    }

    func testSetStatusOnAMissingTargetThrows() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            XCTAssertThrowsError(try WorkbenchOwnerWrites.setStatus(db, targetID: 999_999, status: "done")) {
                XCTAssertTrue($0 is TargetNotFoundError, "\($0)")
            }
        }
    }

    func testSetPriorityWritesAndReportsTheTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)

            let write = try WorkbenchOwnerWrites.setPriority(db, targetID: target, priority: "high")

            XCTAssertEqual(write.touched, [target])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT priority FROM targets WHERE id = ?", arguments: [target]), "high")
        }
    }

    func testAddCommentIsAnOwnerThreadOnTheTarget() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)

            let (id, write) = try WorkbenchOwnerWrites.addComment(db, projectID: pid, targetID: target, body: "  Ship it  ")

            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM project_comments WHERE id = ?", arguments: [id]))
            XCTAssertEqual(row["author"] as String, "owner")
            XCTAssertEqual(row["body"] as String, "Ship it")
            XCTAssertNil(row["parent_id"] as Int64?)
            XCTAssertEqual(write.touched, [target])
        }
    }

    /// A reply to a resolved root reopens the thread, so the agent sees it.
    func testAReplyToAResolvedRootReopensIt() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            let root = try TestDatabase.insertWorkbenchComment(db, projectID: pid, targetID: target, status: "resolved")

            let (id, write) = try WorkbenchOwnerWrites.reply(db, to: root, body: "One more thing")

            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT parent_id FROM project_comments WHERE id = ?", arguments: [id]), root)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM project_comments WHERE id = ?", arguments: [root]), "open")
            XCTAssertEqual(write.touched, [target], "the reply's target is the root's")
        }
    }
}
