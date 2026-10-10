import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A write to a target deleted elsewhere (the agent over the project MCP
/// server, the CLI, a second window) touches no row. Every Desktop target
/// mutator must throw `TargetNotFoundError` for it rather than report a
/// success that never happened — partial failure is not success.
final class TargetQueriesMissingRowTests: XCTestCase {

    private typealias Mutator = (name: String, run: (Database, Int) throws -> Void)

    private let mutators: [Mutator] = [
        ("updateStatus", { try TargetQueries.updateStatus($0, id: $1, status: "done") }),
        ("updatePriority", { try TargetQueries.updatePriority($0, id: $1, priority: "high") }),
        ("updateText", { try TargetQueries.updateText($0, id: $1, text: "renamed") }),
        ("updateIntent", { try TargetQueries.updateIntent($0, id: $1, intent: "why") }),
        ("updateIntent+ifUnchangedFrom", {
            try TargetQueries.updateIntent($0, id: $1, intent: "why", ifUnchangedFrom: "")
        }),
        ("updateDueDate", { try TargetQueries.updateDueDate($0, id: $1, dueDate: "2026-10-01") }),
        ("updateOwnership", { try TargetQueries.updateOwnership($0, id: $1, ownership: "delegated") }),
        ("updateBlocking", { try TargetQueries.updateBlocking($0, id: $1, blocking: "release") }),
        ("updateBallOn", { try TargetQueries.updateBallOn($0, id: $1, ballOn: "colleague A") }),
        ("updateNotes", {
            try TargetQueries.updateNotes($0, id: $1, notes: [TargetNote(text: "n", createdAt: "2026-09-30T00:00:00Z")])
        }),
        ("updateLevel", { try TargetQueries.updateLevel($0, id: $1, level: "week") }),
        ("updateLevel+period", {
            try TargetQueries.updateLevel($0, id: $1, level: "week", periodStart: "2026-09-28", periodEnd: "2026-10-04")
        }),
        ("updateProgress", { try TargetQueries.updateProgress($0, id: $1, progress: 0.5) }),
        ("updateSubItems", { try TargetQueries.updateSubItems($0, id: $1, subItems: [TargetSubItem(text: "s", done: false)]) }),
        ("snooze", { try TargetQueries.snooze($0, id: $1, until: Date()) }),
        ("addTag", { _ = try TargetQueries.addTag($0, id: $1, tag: "ops") }),
        ("removeTag", { _ = try TargetQueries.removeTag($0, id: $1, tag: "ops") })
    ]

    private func createTarget(_ db: Database, text: String = "t") throws -> Int {
        try TargetQueries.create(
            db,
            text: text,
            level: "day",
            periodStart: "2026-09-30",
            periodEnd: "2026-09-30",
            tags: #"["ops"]"#,
            sourceType: "manual",
            sourceID: ""
        )
    }

    func testEveryMutator_ThrowsNotFound_ForATargetDeletedAfterLoad() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int in
            let id = try self.createTarget(db)
            try TargetQueries.delete(db, id: id)
            return id
        }

        for mutator in mutators {
            XCTAssertThrowsError(try queue.write { try mutator.run($0, id) }, mutator.name) { error in
                XCTAssertEqual(error as? TargetNotFoundError, TargetNotFoundError(id: id), mutator.name)
            }
        }
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM targets") }
        XCTAssertEqual(count, 0, "no mutator may resurrect or create a row")
    }

    func testEveryMutator_Succeeds_OnAnExistingTarget_EvenWhenTheValueIsUnchanged() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try self.createTarget($0) }

        // Run each mutator twice: the second run writes the same values, and
        // SQLite still counts the matched row — a repeat must not read as "gone".
        for mutator in mutators {
            XCTAssertNoThrow(try queue.write { try mutator.run($0, id) }, mutator.name)
            XCTAssertNoThrow(try queue.write { try mutator.run($0, id) }, "\(mutator.name) (repeat)")
        }
    }

    func testUpdateParent_ThrowsNotFound_ForADeletedChild_AndLeavesTheParentAlone() throws {
        let queue = try TestDatabase.create()
        let (parent, child) = try queue.write { db -> (Int, Int) in
            let parent = try self.createTarget(db, text: "parent")
            let child = try self.createTarget(db, text: "child")
            try TargetQueries.delete(db, id: child)
            return (parent, child)
        }

        XCTAssertThrowsError(try queue.write { try TargetQueries.updateParent($0, id: child, parentID: parent) }) {
            XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: child))
        }
        let survivor = try queue.read { try TargetQueries.fetchByID($0, id: parent) }
        XCTAssertNotNil(survivor)
    }

    func testUpdateStatus_OnADeletedTarget_LeavesItsInboxItemsPending() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int in
            let id = try self.createTarget(db)
            try db.execute(
                sql: """
                    INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, target_id, status)
                    VALUES ('', '1.0', '', 'target_due', ?, 'pending')
                    """,
                arguments: [id]
            )
            try TargetQueries.delete(db, id: id)
            return id
        }

        XCTAssertThrowsError(try queue.write { try TargetQueries.updateStatus($0, id: id, status: "done") })
        let status = try queue.read {
            try String.fetchOne($0, sql: "SELECT status FROM inbox_items WHERE target_id = ?", arguments: [id])
        }
        XCTAssertEqual(status, "pending", "the INBOX-02 cascade must not run for a write that touched nothing")
    }

    func testNotFoundError_NamesTheTarget() {
        XCTAssertEqual(
            TargetNotFoundError(id: 42).localizedDescription,
            "target #42 no longer exists (it may have been deleted elsewhere)"
        )
    }
}
