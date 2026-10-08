import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// `TargetQueries.hasChildren` decides whether Work on It sends the group
/// prompt (#472): every child row on the same workbench counts, closed or
/// archived ones too — the skill reads the subtree itself.
final class TargetQueriesHasChildrenTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')")
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (2, 'other', '/tmp/other')")
        }
    }

    private func insert(_ id: Int, parent: Int? = nil, project: Int = 1, status: String = "todo") throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, priority, source_type, ownership, parent_id, project_id)
                    VALUES (?, 'Task', 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'medium', 'chat', 'mine', ?, ?)
                    """,
                arguments: [id, status, parent, project]
            )
        }
    }

    private func hasChildren(_ id: Int64, workbench: Int64 = 1) throws -> Bool {
        try queue.read { db in try TargetQueries.hasChildren(db, id: id, workbenchID: workbench) }
    }

    func testALeafHasNoChildren() throws {
        try insert(1)
        XCTAssertFalse(try hasChildren(1))
    }

    func testADismissedOnlyChildStillCounts() throws {
        try insert(1)
        try insert(2, parent: 1, status: "dismissed")
        XCTAssertTrue(try hasChildren(1), "closed children count; the skill reads the subtree itself")
    }

    func testAChildOnAnotherWorkbenchDoesNotCount() throws {
        try insert(1)
        try insert(2, parent: 1, project: 2)
        XCTAssertFalse(try hasChildren(1))
    }
}
