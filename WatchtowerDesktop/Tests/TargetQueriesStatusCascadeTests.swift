import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop

/// BEHAVIOR INBOX-02 — closing a target must resolve its pending `target_due`
/// inbox items so the user never has to close the same thing twice. The Go side
/// does this in `UpdateTargetStatus` (internal/db/targets.go); Desktop "Done"
/// goes through `TargetQueries.updateStatus` directly (bypassing Go), so the
/// cascade is mirrored here per the established dual-path convention (see
/// `CatchUpQueries.acknowledge`).
final class TargetQueriesStatusCascadeTests: XCTestCase {

    /// Seeds a target with two pending inbox items linked to it:
    /// one `target_due` (must cascade) and one `mention` (must not).
    private func makeFixture() throws -> (queue: DatabaseQueue, targetID: Int) {
        let queue = try TestDatabase.create()
        let targetID = try queue.write { db -> Int in
            let id = Int(try TestDatabase.insertTarget(db))
            try TestDatabase.insertInboxItem(
                db, messageTS: "1700000001.000100", triggerType: "target_due", taskID: id
            )
            try TestDatabase.insertInboxItem(
                db, messageTS: "1700000002.000100", triggerType: "mention", taskID: id
            )
            return id
        }
        return (queue, targetID)
    }

    private func inboxRows(_ queue: DatabaseQueue) throws -> [Row] {
        try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT trigger_type, status, resolved_reason FROM inbox_items ORDER BY message_ts"
            )
        }
    }

    func testUpdateStatusDone_ResolvesPendingTargetDueItems() throws {
        let (queue, targetID) = try makeFixture()

        try queue.write { try TargetQueries.updateStatus($0, id: targetID, status: "done") }

        let rows = try inboxRows(queue)
        XCTAssertEqual(rows[0]["trigger_type"], "target_due")
        XCTAssertEqual(rows[0]["status"], "resolved")
        XCTAssertEqual(rows[0]["resolved_reason"], "target_closed")
    }

    func testUpdateStatusDismissed_ResolvesPendingTargetDueItems() throws {
        let (queue, targetID) = try makeFixture()

        try queue.write { try TargetQueries.updateStatus($0, id: targetID, status: "dismissed") }

        let rows = try inboxRows(queue)
        XCTAssertEqual(rows[0]["status"], "resolved")
        XCTAssertEqual(rows[0]["resolved_reason"], "target_closed")
    }

    func testUpdateStatusDone_LeavesNonTargetDueItemsPending() throws {
        let (queue, targetID) = try makeFixture()

        try queue.write { try TargetQueries.updateStatus($0, id: targetID, status: "done") }

        let rows = try inboxRows(queue)
        XCTAssertEqual(rows[1]["trigger_type"], "mention")
        XCTAssertEqual(rows[1]["status"], "pending")
        XCTAssertEqual(rows[1]["resolved_reason"], "")
    }

    func testUpdateStatusNonClosing_LeavesTargetDueItemsPending() throws {
        let (queue, targetID) = try makeFixture()

        try queue.write { try TargetQueries.updateStatus($0, id: targetID, status: "in_progress") }

        let rows = try inboxRows(queue)
        XCTAssertEqual(rows[0]["status"], "pending")
        XCTAssertEqual(rows[1]["status"], "pending")
    }

    /// The cascade only touches items linked to the closed target — a pending
    /// `target_due` item for a different target must stay pending.
    func testUpdateStatusDone_LeavesOtherTargetsItemsPending() throws {
        let queue = try TestDatabase.create()
        let (closedID, otherID) = try queue.write { db -> (Int, Int) in
            let a = Int(try TestDatabase.insertTarget(db, text: "closed"))
            let b = Int(try TestDatabase.insertTarget(db, text: "other"))
            try TestDatabase.insertInboxItem(
                db, messageTS: "1700000003.000100", triggerType: "target_due", taskID: b
            )
            return (a, b)
        }

        try queue.write { try TargetQueries.updateStatus($0, id: closedID, status: "done") }

        let status = try queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT status FROM inbox_items WHERE target_id = ?", arguments: [otherID]
            )
        }
        XCTAssertEqual(status, "pending")
    }
}
