import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Desktop-only target writers that change a child's progress or status must
/// recompute the parent chain the same way Go does. The writers with a Go twin
/// are pinned by the shared fixture (`TargetProgressFixtureTests`); these are
/// the ones without one: the progress slider, snooze, the day-plan cascade,
/// plus the degenerate inputs of the helper itself.
final class TargetQueriesParentProgressTests: XCTestCase {

    /// root(1) ← mid(2) ← leaf(3, todo 0.0) + leaf(4, done 1.0); mid and root at 0.5.
    private func makeTree() throws -> DatabaseQueue {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertTarget(db, text: "root", progress: 0.5)
            try TestDatabase.insertTarget(db, text: "mid", parentId: 1, progress: 0.5)
            try TestDatabase.insertTarget(db, text: "leaf-a", parentId: 2, status: "todo", progress: 0.0)
            try TestDatabase.insertTarget(db, text: "leaf-b", parentId: 2, status: "done", progress: 1.0)
        }
        return queue
    }

    private func progress(_ queue: DatabaseQueue, _ id: Int) throws -> Double {
        try queue.read { db in
            try XCTUnwrap(Double.fetchOne(db, sql: "SELECT progress FROM targets WHERE id = ?", arguments: [id]))
        }
    }

    func testUpdateProgress_RecomputesEveryAncestor() throws {
        let queue = try makeTree()

        try queue.write { try TargetQueries.updateProgress($0, id: 3, progress: 0.5) }

        XCTAssertEqual(try progress(queue, 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 2), 0.75, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 1), 0.75, accuracy: 1e-9)
    }

    func testSnooze_ZeroesLeafProgressAndRecomputesParent() throws {
        let queue = try makeTree()

        try queue.write { try TargetQueries.snooze($0, id: 4, until: Date()) }

        XCTAssertEqual(try progress(queue, 4), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 2), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 1), 0.0, accuracy: 1e-9)
    }

    func testUpdateStatus_OnParentWithChildren_KeepsChildAverage() throws {
        let queue = try makeTree()

        // mid has non-dismissed children, so its own status must not overwrite
        // the average (Go's leaf-only UPDATE ... NOT EXISTS guard).
        try queue.write { try TargetQueries.updateStatus($0, id: 2, status: "done") }

        XCTAssertEqual(try progress(queue, 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 1), 0.5, accuracy: 1e-9)
    }

    func testDayPlanCascade_RecomputesTaskParent() throws {
        let queue = try makeTree()
        let itemID = try queue.write { db -> Int64 in
            let planID = try TestDatabase.insertDayPlan(db, userID: "U1")
            return try TestDatabase.insertDayPlanItem(
                db, dayPlanID: planID, kind: "backlog", sourceType: "task", sourceID: "3", title: "leaf-a"
            )
        }

        try queue.write { try DayPlanQueries.markItemDone($0, itemId: itemID, cascadeToTask: true) }

        XCTAssertEqual(try progress(queue, 3), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 2), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 1), 1.0, accuracy: 1e-9)
    }

    func testUpdateParent_ToSameParent_LeavesProgressAlone() throws {
        let queue = try makeTree()

        try queue.write { try TargetQueries.updateParent($0, id: 3, parentID: 2) }

        XCTAssertEqual(try progress(queue, 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 1), 0.5, accuracy: 1e-9)
    }

    func testRecompute_UnknownParent_IsANoOp() throws {
        let queue = try makeTree()

        try queue.write { try TargetQueries.recomputeParentProgress($0, parentID: 999) }

        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM targets") }
        XCTAssertEqual(count, 4)
        XCTAssertEqual(try progress(queue, 1), 0.5, accuracy: 1e-9)
    }

    func testCreate_ExplicitProgress_IsKeptOnTheNewRow() throws {
        let queue = try makeTree()

        let newID = try queue.write { db in
            try TargetQueries.create(
                db, text: "child", periodStart: "2026-01-01", periodEnd: "2026-01-01",
                parentId: 2, progress: 1.0
            )
        }

        XCTAssertEqual(try progress(queue, newID), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try progress(queue, 2), 2.0 / 3.0, accuracy: 1e-9)
    }
}
