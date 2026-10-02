import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchDeleteSummaryTests: XCTestCase {

    func testFetchCountsOnlyThisProjectsRows() throws {
        let queue = try TestDatabase.create()
        let project = try queue.write { db -> Workbench in
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('other', '/tmp/other')")
            let other = db.lastInsertedRowID
            for (text, p) in [("a", pid), ("b", pid), ("c", other)] {
                try db.execute(
                    sql: """
                        INSERT INTO targets (text, level, custom_label, period_start, period_end,
                            status, source_type, ownership, project_id)
                        VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', 'todo', 'chat', 'mine', ?)
                        """,
                    arguments: [text, p]
                )
            }
            try db.execute(sql: "INSERT INTO project_documents (project_id, rel_path) VALUES (?, 'docs/plan.md')",
                           arguments: [pid])
            let doc = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO project_comments (project_id, document_id, author, body) VALUES (?, ?, 'owner', 'x')",
                           arguments: [pid, doc])
            return try XCTUnwrap(WorkbenchQueries.fetch(db, id: pid))
        }
        let summary = try queue.read { try WorkbenchDeleteSummary.fetch($0, project: project) }
        XCTAssertEqual(summary.targets, 2)
        XCTAssertEqual(summary.documents, 1)
        XCTAssertEqual(summary.comments, 1)
        XCTAssertEqual(summary.folder, "/tmp/acme")
    }

    func testMessageListsWhatIsRemovedAndWhatIsKept() {
        let s = WorkbenchDeleteSummary(name: "acme", folder: "/tmp/acme", targets: 1, documents: 2, comments: 0)
        XCTAssertEqual(s.title, "Delete project “acme”?")
        XCTAssertTrue(s.message.contains("1 target, 2 documents and 0 comments"))
        XCTAssertTrue(s.message.contains("watchtower-project skill"))
        XCTAssertTrue(s.message.contains("SessionStart hook"))
        XCTAssertTrue(s.message.contains("MCP registration"))
        XCTAssertTrue(s.message.contains(".git/info/exclude"))
        XCTAssertTrue(s.message.contains("A skill you edited is kept"), "an edited skill is the owner's (PROJ-04)")
        XCTAssertTrue(s.message.contains("exclude line whose file still exists"))
        XCTAssertTrue(s.message.contains("/tmp/acme"))
        XCTAssertTrue(s.message.contains("files themselves stay"), "attached documents are never deleted from disk")
        XCTAssertTrue(s.message.contains("copies of images attached to targets are deleted"))
        XCTAssertTrue(s.message.contains("terminal"), "the owner is told the running session is closed")
    }
}
