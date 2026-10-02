import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// BEHAVIOR PROJ-09 — a workbench target moves under another target of its
/// workbench or to the top level, never into a cycle or across workbenches,
/// and both parents re-derive their status (PROJ-05) and progress. The
/// Desktop half of Go `MoveWorkbenchTargetTx` (`TestProj09_*`).
final class WorkbenchMoveTargetTests: XCTestCase {

    private func parent(_ db: Database, _ id: Int64) throws -> Int64? {
        try Row.fetchOne(db, sql: "SELECT parent_id FROM targets WHERE id = ?", arguments: [id])?["parent_id"]
    }

    private func status(_ db: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [id])
    }

    private func progress(_ db: Database, _ id: Int64) throws -> Double? {
        try Double.fetchOne(db, sql: "SELECT progress FROM targets WHERE id = ?", arguments: [id])
    }

    func testProj09_MoveReRollsBothParentsStatusAndProgress() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let from = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "From")
            let to = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "To")
            let moving = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress", parentID: from)
            let stays = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "done", parentID: from)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, parentID: to)
            try TargetQueries.updateProgress(db, id: Int(moving), progress: 0.5)
            try TargetQueries.updateProgress(db, id: Int(stays), progress: 1)
            XCTAssertEqual(try status(db, from), "in_progress")

            try WorkbenchQueries.moveTarget(db, projectID: pid, targetID: moving, parentID: to)

            XCTAssertEqual(try parent(db, moving), to)
            XCTAssertEqual(try status(db, from), "done", "the old parent keeps only its done child")
            XCTAssertEqual(try status(db, to), "in_progress", "the new parent gains a started child")
            XCTAssertEqual(try XCTUnwrap(progress(db, from)), 1, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(progress(db, to)), 0.25, accuracy: 1e-9, "avg of 0 and 0.5")

            try WorkbenchQueries.moveTarget(db, projectID: pid, targetID: moving, parentID: nil)
            XCTAssertNil(try parent(db, moving), "moved to the top level")
            XCTAssertEqual(try status(db, to), "todo")
        }
    }

    func testProj09_MoveRefusesACycle() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            let mid = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, parentID: root)
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, parentID: mid)
            for candidate in [root, mid, leaf] {
                XCTAssertThrowsError(try WorkbenchQueries.moveTarget(db, projectID: pid, targetID: root, parentID: candidate)) {
                    XCTAssertEqual($0 as? TargetParentCycleError, TargetParentCycleError(id: root, parentID: candidate))
                }
                XCTAssertNil(try parent(db, root), "nothing written")
            }
        }
    }

    func testProj09_MoveRefusesAnotherBoard() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            let mine = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            let theirs = try TestDatabase.insertWorkbenchTarget(db, projectID: other)
            try db.execute(sql: """
                INSERT INTO targets (text, level, period_start, period_end, source_type)
                VALUES ('personal', 'day', '2026-09-29', '2026-09-29', 'manual')
                """)
            let personal = db.lastInsertedRowID

            let cases: [(String, Int64, Int64?)] = [
                ("parent on another workbench", mine, theirs),
                ("personal parent", mine, personal),
                ("missing parent", mine, 99_999),
                ("target of another workbench", theirs, mine),
                ("target of another workbench to the top level", theirs, nil),
                ("personal target", personal, mine),
                ("missing target", 99_999, mine)
            ]
            for (name, id, parentID) in cases {
                XCTAssertThrowsError(try WorkbenchQueries.moveTarget(db, projectID: pid, targetID: id, parentID: parentID), name) {
                    XCTAssertEqual($0 as? WorkbenchQueryError, .wrongWorkbench, name)
                }
            }
            XCTAssertNil(try parent(db, mine))
            XCTAssertNil(try parent(db, theirs))
        }
    }

    /// The generic reparent (`TargetQueries.updateParent`, Suggest Links)
    /// refuses a cycle too, like Go `UpdateTarget`.
    func testProj09_UpdateParentRefusesACycle() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            let child = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, parentID: root)
            let other = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            XCTAssertThrowsError(try TargetQueries.updateParent(db, id: Int(root), parentID: Int(child))) {
                XCTAssertEqual($0 as? TargetParentCycleError, TargetParentCycleError(id: root, parentID: child))
            }
            XCTAssertNil(try parent(db, root), "nothing written")
            try TargetQueries.updateParent(db, id: Int(child), parentID: Int(other))
            XCTAssertEqual(try parent(db, child), other)
        }
    }

    func testProj09_UnchangedParentWritesNothing() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            let child = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, parentID: root)
            try db.execute(sql: "UPDATE targets SET updated_at = '2020-01-01T00:00:00Z' WHERE id = ?", arguments: [child])

            try WorkbenchQueries.moveTarget(db, projectID: pid, targetID: child, parentID: root)

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT updated_at FROM targets WHERE id = ?", arguments: [child]),
                "2020-01-01T00:00:00Z"
            )
        }
    }
}
