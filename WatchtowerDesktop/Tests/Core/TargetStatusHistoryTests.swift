import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// PROJ-06 on the Desktop side: in_review decodes and is open, the Desktop's
/// status writers claim the owner, and the history reads back oldest first.
final class TargetStatusHistoryTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    func testDesktopStatusWritesAreRecordedAsTheOwners() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            let id = try TestDatabase.insertProjectTarget(d, projectID: p)
            // The agent's write, as the Go MCP path makes it.
            try d.execute(sql: "UPDATE targets SET status = 'in_review', status_actor = 'agent' WHERE id = ?",
                          arguments: [id])
            try TargetQueries.updateStatus(d, id: Int(id), status: "done")

            let history = try TargetQueries.statusHistory(d, targetID: id)
            XCTAssertEqual(history.map(\.toStatus), ["todo", "in_review", "done"])
            XCTAssertEqual(history.map(\.fromStatus), [nil, "todo", "in_review"])
            XCTAssertEqual(history.map(\.actor), ["owner", "agent", "owner"])
            XCTAssertNil(try String.fetchOne(d, sql: "SELECT status_actor FROM targets WHERE id = ?", arguments: [id]),
                         "the claim is cleared by its own write")
        }
    }

    func testInReviewDecodesAsActiveWithProgressAndBoardRank() throws {
        try db.write { d in
            let p = try TestDatabase.insertProject(d)
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, text: "blocked one", status: "blocked")
            _ = try TestDatabase.insertProjectTarget(d, projectID: p, text: "review one", status: "in_review")
            let board = try ProjectQueries.board(d, projectID: p)
            XCTAssertEqual(board.map(\.target.text), ["review one", "blocked one"], "in_review ranks before blocked")
            let review = board[0].target
            XCTAssertEqual(review.status, "in_review")
            XCTAssertTrue(review.isActive)
            XCTAssertEqual(TargetQueries.statusProgress("in_review"), 0.8, accuracy: 1e-9)

            let summary = try XCTUnwrap(ProjectQueries.summaries(d).first)
            XCTAssertEqual(summary.openTargets, 2)
            XCTAssertEqual(summary.inProgressTargets, 0, "like the CLI, in progress excludes in_review")
        }
    }

    func testInReviewIsRejectedOnAPersonalTarget() throws {
        try db.write { d in
            let id = try TargetQueries.create(d, text: "personal", level: "day",
                                              periodStart: "2026-09-30", periodEnd: "2026-09-30")
            XCTAssertThrowsError(try TargetQueries.updateStatus(d, id: id, status: "in_review"))
            XCTAssertEqual(try TargetQueries.statusHistory(d, targetID: Int64(id)), [])
        }
    }
}
