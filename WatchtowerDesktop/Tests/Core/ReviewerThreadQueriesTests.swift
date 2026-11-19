import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The reviewer's threads (migration 00180): one conversation per
/// (workbench, branch), made on first use and shared by every session on
/// that branch; it goes with its workbench.
final class ReviewerThreadQueriesTests: XCTestCase {
    func testEnsureMakesOneThreadPerBranch() throws {
        let db = try TestDatabase.create()
        let project = try db.write { try TestDatabase.insertWorkbench($0) }
        XCTAssertNil(try db.read { try ReviewerThreadQueries.conversationID($0, projectID: project, branch: "feature/a") })

        let first = try db.write { try ReviewerThreadQueries.ensure($0, projectID: project, branch: "feature/a") }
        let again = try db.write { try ReviewerThreadQueries.ensure($0, projectID: project, branch: "feature/a") }
        let other = try db.write { try ReviewerThreadQueries.ensure($0, projectID: project, branch: "feature/b") }
        XCTAssertEqual(first, again, "a second session on the branch shares the thread")
        XCTAssertNotEqual(first, other, "a renamed or another branch starts a new thread")
        XCTAssertEqual(try db.read { try ReviewerThreadQueries.conversationID($0, projectID: project, branch: "feature/a") }, first)
        let keyFolder = try db.read {
            try Int64.fetchOne($0, sql: "SELECT workbench_folder_id FROM review_reviewer_threads WHERE conversation_id = ?",
                               arguments: [first])
        }
        let home = try db.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM workbench_folders WHERE workbench_id = ?", arguments: [project])
        }
        XCTAssertNotNil(home)
        XCTAssertEqual(keyFolder, home, "the thread is keyed by the workbench's home folder (00209)")

        let conversation = try XCTUnwrap(try db.read { try ChatConversationQueries.fetchByID($0, id: first) })
        XCTAssertEqual(conversation.contextType, "review_reviewer")
        XCTAssertEqual(conversation.contextID, "\(project):feature/a")
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations") }, 2)
    }

    /// A legacy bench whose only folder row migration 00209 marked removed
    /// (another spelling of an older bench's folder) still gets its threads.
    func testALegacyBenchWithARemovedOnlyFolderGetsThreads() throws {
        let db = try TestDatabase.create()
        let project = try db.write { try TestDatabase.insertWorkbench($0) }
        try db.write {
            try $0.execute(sql: "UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE workbench_id = ?",
                           arguments: [project])
        }
        let first = try db.write { try ReviewerThreadQueries.ensure($0, projectID: project, branch: "feature/a") }
        let again = try db.write { try ReviewerThreadQueries.ensure($0, projectID: project, branch: "feature/a") }
        XCTAssertEqual(first, again)
    }

    func testTheThreadGoesWithItsWorkbench() throws {
        let db = try TestDatabase.create()
        let (mine, other) = try db.write { db in
            (try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme"),
             try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other"))
        }
        let gone = try db.write { try ReviewerThreadQueries.ensure($0, projectID: mine, branch: "feature/a") }
        let kept = try db.write { try ReviewerThreadQueries.ensure($0, projectID: other, branch: "feature/a") }
        try db.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [mine]) }
        XCTAssertNil(try db.read { try ChatConversationQueries.fetchByID($0, id: gone) })
        XCTAssertNotNil(try db.read { try ChatConversationQueries.fetchByID($0, id: kept) })
    }
}
