import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// BEHAVIOR PROJ-05 — a project parent's status never lags its children.
/// The rule lives in migration 00085's triggers, so a Desktop write through
/// GRDB rolls the parent up exactly like a Go write, with no Swift port.
final class WorkbenchStatusRollupTests: XCTestCase {

    private func status(_ db: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [id])
    }

    func testGRDBChildStatusUpdateRollsTheChainUp() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Plan")
            let mid = try TestDatabase.insertWorkbenchTarget(db, projectID: project, parentID: root)
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: project, parentID: mid)
            XCTAssertEqual(try status(db, root), "todo")

            try TargetQueries.updateStatus(db, id: Int(leaf), status: "in_progress")
            XCTAssertEqual(try status(db, mid), "in_progress")
            XCTAssertEqual(try status(db, root), "in_progress")

            try TargetQueries.updateStatus(db, id: Int(leaf), status: "done")
            XCTAssertEqual(try status(db, mid), "done")
            XCTAssertEqual(try status(db, root), "done")
        }
    }

    func testGRDBParentOwnUpdateStandsAndChildDeleteReRollsIt() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let parent = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: project, status: "done", parentID: parent)
            let open = try TestDatabase.insertWorkbenchTarget(db, projectID: project, parentID: parent)
            XCTAssertEqual(try status(db, parent), "in_progress")

            try TargetQueries.updateStatus(db, id: Int(parent), status: "blocked")
            XCTAssertEqual(try status(db, parent), "blocked", "the parent's own update is not rolled up")

            try TargetQueries.delete(db, id: Int(open))
            XCTAssertEqual(try status(db, parent), "done", "the remaining child is done")
        }
    }

    func testDeletingAProjectWithAMultiLevelBoardLeavesNoTargets() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Plan")
            for _ in 0..<3 {
                let mid = try TestDatabase.insertWorkbenchTarget(db, projectID: project, status: "in_progress", parentID: root)
                let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: project, parentID: mid)
                _ = try TestDatabase.insertWorkbenchTarget(db, projectID: project, status: "done", parentID: leaf)
            }
            let keep = try TestDatabase.insertWorkbenchTarget(db, projectID: other, text: "Other plan")
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: other, status: "in_progress", parentID: keep)

            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [project])

            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets WHERE project_id = ?", arguments: [project]),
                0
            )
            XCTAssertEqual(try status(db, keep), "in_progress", "another project's board is untouched")
        }
    }
}
