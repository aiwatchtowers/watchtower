import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The reviewer's threads (migration 00175): one conversation per
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

        let conversation = try XCTUnwrap(try db.read { try ChatConversationQueries.fetchByID($0, id: first) })
        XCTAssertEqual(conversation.contextType, "review_reviewer")
        XCTAssertEqual(conversation.contextID, "\(project):feature/a")
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations") }, 2)
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
