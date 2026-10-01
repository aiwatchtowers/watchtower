import XCTest
import GRDB
import WatchtowerTestSupport

/// The test schema mirror must carry migration 00081 (projects) so Desktop
/// queries written against it see the real shape.
final class ProjectSchemaMirrorTests: XCTestCase {
    func testMirrorHasProjectTablesAndTargetsProjectID() throws {
        let queue = try TestDatabase.create()
        try queue.read { db in
            for table in ["projects", "project_sources", "project_documents", "project_comments", "project_target_images"] {
                XCTAssertTrue(try db.tableExists(table), "missing \(table)")
            }
            let columns = try db.columns(in: "targets").map(\.name)
            XCTAssertTrue(columns.contains("project_id"))
        }
    }

    func testDeletingAProjectCascadesToItsTargetsAndComments() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let projectID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO targets (text, period_start, period_end, project_id)
                VALUES ('board item', '2026-09-29', '2026-09-29', ?)
                """,
                arguments: [projectID]
            )
            let targetID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'agent', 'q')",
                arguments: [projectID, targetID]
            )
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_comments"), 0)
        }
    }
}
