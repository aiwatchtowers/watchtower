import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectBoardOutlineTests: XCTestCase {

    // Builds real Target rows through the DB so the fixture never drifts from
    // Target's own row decoding.
    private func target(_ id: Int, _ text: String, status: String = "todo") throws -> Target {
        let queue = try TestDatabase.create()
        return try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, source_type, ownership)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'chat', 'mine')
                    """,
                arguments: [id, text, status]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [ProjectBoardNode] = []) -> ProjectBoardNode {
        ProjectBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, documents: [])
    }

    func testRowsFlattenDepthFirstWithDepth() throws {
        let tree = [
            node(try target(1, "Feature"), [
                node(try target(2, "Task 1")),
                node(try target(3, "Task 2"), [node(try target(4, "Step"))])
            ]),
            node(try target(5, "Other"))
        ]
        let rows = ProjectBoardOutline.rows(tree, collapsed: [], showDone: true)
        XCTAssertEqual(rows.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 0])
        XCTAssertEqual(rows.map(\.hasChildren), [true, false, true, false, false])
    }

    func testCollapsedNodeHidesItsSubtreeButNotItself() throws {
        let tree = [node(try target(1, "Feature"), [node(try target(2, "Task"), [node(try target(3, "Step"))])])]
        let rows = ProjectBoardOutline.rows(tree, collapsed: [2], showDone: true)
        XCTAssertEqual(rows.map(\.id), [1, 2])
    }

    func testHideDoneKeepsADoneParentWithAnOpenChild() throws {
        let tree = [
            node(try target(1, "Done feature", status: "done"), [
                node(try target(2, "Open task")),
                node(try target(3, "Done task", status: "done"))
            ]),
            node(try target(4, "Dismissed", status: "dismissed"))
        ]
        let rows = ProjectBoardOutline.rows(tree, collapsed: [], showDone: false)
        XCTAssertEqual(rows.map(\.id), [1, 2], "a closed node stays while any descendant is open")
    }

    func testFindLocatesANestedNode() throws {
        let tree = [node(try target(1, "Feature"), [node(try target(2, "Task"))])]
        XCTAssertEqual(ProjectBoardOutline.find(2, in: tree)?.target.text, "Task")
        XCTAssertNil(ProjectBoardOutline.find(99, in: tree))
    }
}
