import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A target's parent must be on the same board — the Swift twin of Go
/// `checkParentBoard` (internal/db/targets_board.go). NULL vs N is different.
final class TargetParentBoardTests: XCTestCase {
    private func workbenchTarget(_ db: Database, text: String) throws -> Int {
        try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
        let projectID = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO targets (text, level, custom_label, period_start, period_end, status, source_type, ownership, project_id)
            VALUES (?, 'custom', 'project', '2026-09-30', '2026-09-30', 'todo', 'chat', 'mine', ?)
            """, arguments: [text, projectID])
        return Int(db.lastInsertedRowID)
    }

    private func personal(_ db: Database, text: String, parent: Int? = nil) throws -> Int {
        try TargetQueries.create(db, text: text, periodStart: "2026-09-30", periodEnd: "2026-09-30", parentId: parent)
    }

    private func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM targets") ?? 0
    }

    func testPersonalChildUnderAProjectParentIsRefused() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let board = try workbenchTarget(db, text: "Board task")
            let before = try count(db)
            XCTAssertThrowsError(try personal(db, text: "Mine", parent: board)) { error in
                XCTAssertTrue(error is TargetParentBoardError)
                XCTAssertTrue(error.localizedDescription.contains("must be on the same board"))
            }
            XCTAssertEqual(try count(db), before, "nothing written")

            let loose = try personal(db, text: "Loose")
            XCTAssertThrowsError(try TargetQueries.updateParent(db, id: loose, parentID: board))
            XCTAssertNil(try TargetQueries.parentID(db, of: loose), "the move wrote nothing")
        }
    }

    func testProjectChildUnderAPersonalParentIsRefused() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let mine = try personal(db, text: "Mine")
            let board = try workbenchTarget(db, text: "Board task")
            XCTAssertThrowsError(try TargetQueries.updateParent(db, id: board, parentID: mine)) { error in
                XCTAssertEqual(
                    error as? TargetParentBoardError,
                    TargetParentBoardError(parentID: mine, parentWorkbenchID: nil, childWorkbenchID: 1)
                )
            }
            XCTAssertNil(try TargetQueries.parentID(db, of: board))
        }
    }

    func testSameBoardParentIsAccepted() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let parent = try personal(db, text: "Parent")
            let child = try personal(db, text: "Child", parent: parent)
            XCTAssertEqual(try TargetQueries.parentID(db, of: child), parent)
            let other = try personal(db, text: "Other")
            try TargetQueries.updateParent(db, id: child, parentID: other)
            XCTAssertEqual(try TargetQueries.parentID(db, of: child), other)
        }
    }
}
