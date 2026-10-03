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
            try db.execute(sql: "INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'question', 'Which?')",
                           arguments: [pid])
            try db.execute(sql: "INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'question', 'Other')",
                           arguments: [other])
            let target = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM targets WHERE text = 'a'"))
            try db.execute(sql: "INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'owner', 'x')",
                           arguments: [pid, target])
            return try XCTUnwrap(WorkbenchQueries.fetch(db, id: pid))
        }
        let summary = try queue.read { try WorkbenchDeleteSummary.fetch($0, project: project, vocabulary: .current) }
        XCTAssertEqual(summary.targets, 2)
        XCTAssertEqual(summary.asks, 1)
        XCTAssertEqual(summary.comments, 1)
        XCTAssertEqual(summary.folder, "/tmp/acme")
    }

    func testMessageListsWhatIsRemovedAndWhatIsKept() {
        let s = WorkbenchDeleteSummary(name: "acme", folder: "/tmp/acme", targets: 1, asks: 2, comments: 0)
        XCTAssertEqual(s.title, "Delete workbench “acme”?")
        XCTAssertTrue(s.message.contains("1 target, 2 asks and 0 comments"))
        XCTAssertTrue(s.message.contains("the watchtower-workbench skill"))
        XCTAssertTrue(s.message.contains("SessionStart hook"))
        XCTAssertTrue(s.message.contains("the watchtower-workbench MCP registration"))
        XCTAssertFalse(s.message.contains("watchtower-project"))
        XCTAssertTrue(s.message.contains(".git/info/exclude"))
        XCTAssertTrue(s.message.contains("A skill you edited is kept"), "an edited skill is the owner's (PROJ-04)")
        XCTAssertTrue(s.message.contains("exclude line whose file still exists"))
        XCTAssertTrue(s.message.contains("/tmp/acme"))
        XCTAssertTrue(s.message.contains("files in the folder themselves stay"), "the folder's files are never deleted")
        XCTAssertTrue(s.message.contains("copies of images attached to targets are deleted"))
        XCTAssertTrue(s.message.contains("terminal"), "the owner is told the running session is closed")
    }

    /// A folder set up before the Workbench rename has the old skill and
    /// server (spec 2026-10-02 §5.5): the confirmation names those.
    func testALegacyFolderNamesTheOldSkillAndServer() {
        let s = WorkbenchDeleteSummary(name: "acme", folder: "/tmp/acme", targets: 0, asks: 0, comments: 0,
                                       vocabulary: .legacy)
        XCTAssertTrue(s.message.contains("the watchtower-project skill"))
        XCTAssertTrue(s.message.contains("the watchtower-project MCP registration"))
        XCTAssertFalse(s.message.contains("watchtower-workbench"))
    }
}
