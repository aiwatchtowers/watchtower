import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchBoardOutlineTests: XCTestCase {

    // Builds real Target rows through the DB so the fixture never drifts from
    // Target's own row decoding.
    private func target(_ id: Int, _ text: String, status: String = "todo", intent: String = "") throws -> Target {
        let queue = try TestDatabase.create()
        return try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, intent, level, custom_label, period_start, period_end,
                        status, source_type, ownership)
                    VALUES (?, ?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'chat', 'mine')
                    """,
                arguments: [id, text, intent, status]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = []) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, documents: [])
    }

    func testRowsFlattenDepthFirstWithDepth() throws {
        let tree = [
            node(try target(1, "Feature"), [
                node(try target(2, "Task 1")),
                node(try target(3, "Task 2"), [node(try target(4, "Step"))])
            ]),
            node(try target(5, "Other"))
        ]
        let rows = WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: true)
        XCTAssertEqual(rows.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 0])
        XCTAssertEqual(rows.map(\.hasChildren), [true, false, true, false, false])
    }

    func testCollapsedNodeHidesItsSubtreeButNotItself() throws {
        let tree = [node(try target(1, "Feature"), [node(try target(2, "Task"), [node(try target(3, "Step"))])])]
        let rows = WorkbenchBoardOutline.rows(tree, collapsed: [2], showDone: true)
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
        let rows = WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false)
        XCTAssertEqual(rows.map(\.id), [1, 2], "a closed node stays while any descendant is open")
    }

    func testFindLocatesANestedNode() throws {
        let tree = [node(try target(1, "Feature"), [node(try target(2, "Task"))])]
        XCTAssertEqual(WorkbenchBoardOutline.find(2, in: tree)?.target.text, "Task")
        XCTAssertNil(WorkbenchBoardOutline.find(99, in: tree))
    }

    // MARK: - Search (board #207)

    private func searchTree() throws -> [WorkbenchBoardNode] {
        [
            node(try target(1, "Comments group"), [
                node(try target(163, "Artifact comments")),
                node(try target(7, "Document comments", status: "done"))
            ]),
            node(try target(2, "Meeting widget", intent: "Show the next meeting"), [
                node(try target(3, "Widget layout", status: "dismissed"))
            ]),
            node(try target(4, "Release v163 notes"))
        ]
    }

    func testHashNumberFindsOnlyThatTargetWithItsAncestors() throws {
        let rows = WorkbenchBoardOutline.rows(try searchTree(), collapsed: [], showDone: false, query: "#163")
        XCTAssertEqual(rows.map(\.id), [1, 163], "#163 is the id only — never a title containing 163")
        XCTAssertEqual(rows.map(\.depth), [0, 1])
    }

    func testBareNumberFindsTheIdAndTitlesContainingIt() throws {
        let rows = WorkbenchBoardOutline.rows(try searchTree(), collapsed: [], showDone: false, query: " 163 ")
        XCTAssertEqual(rows.map(\.id), [1, 163, 4])
    }

    func testTextMatchesTitleOrIntentIgnoringCase() throws {
        let tree = try searchTree()
        XCTAssertEqual(WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false, query: "NEXT MEETING").map(\.id), [2, 3],
                       "an intent match keeps its subtree, dismissed child included")
        XCTAssertEqual(WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false, query: "document").map(\.id), [1, 7],
                       "a search finds a done target with Show done off")
    }

    func testSearchIgnoresCollapse() throws {
        let rows = WorkbenchBoardOutline.rows(try searchTree(), collapsed: [1], showDone: false, query: "artifact")
        XCTAssertEqual(rows.map(\.id), [1, 163], "a match inside a collapsed parent is shown")
    }

    func testBlankQueryIsNoSearchAndNoMatchIsEmpty() throws {
        let tree = try searchTree()
        XCTAssertEqual(WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false, query: "  ").map(\.id),
                       WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false).map(\.id))
        XCTAssertTrue(WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false, query: "#999").isEmpty)
        XCTAssertTrue(WorkbenchBoardOutline.rows(tree, collapsed: [], showDone: false, query: "#").isEmpty,
                      "a lone # is text, and no title contains it")
    }
}
