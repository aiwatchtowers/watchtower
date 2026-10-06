import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The side panel's group mode (spec 2026-10-06 Part 3): the "N of M done"
/// summary with its per-status breakdown and the SUB-TASKS tree.
final class WorkbenchGroupPanelTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
        // in_review is a project-only status (CHECK): every fixture target
        // lives on project 1.
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')")
        }
    }

    private func target(_ id: Int, _ text: String = "Task", status: String = "todo") throws -> Target {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, source_type, ownership, project_id)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'chat', 'mine', 1)
                    """,
                arguments: [id, text, status]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = [], archived: Bool = false) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, archived: archived)
    }

    private func leaf(_ id: Int, _ status: String, archived: Bool = false) throws -> WorkbenchBoardNode {
        node(try target(id, "Task \(id)", status: status), archived: archived)
    }

    private func labels(_ rows: [WorkbenchSubtaskTree.Row]) -> [String] {
        rows.map { row in
            switch row {
            case let .target(row): String(repeating: "  ", count: row.depth) + "#\(row.id)"
            case let .closed(fold): String(repeating: "  ", count: fold.depth) + "closed \(fold.count)\(fold.unfolded ? " open" : "")"
            }
        }
    }

    // MARK: - Summary

    func testSummaryCountsTheGroupsLeavesAtEveryDepth() throws {
        let nested = node(try target(10, "Nested group", status: "in_progress"), [
            try leaf(11, "done"),
            try leaf(12, "in_progress")
        ])
        let group = node(try target(1, "Group", status: "in_progress"), [
            try leaf(2, "done"),
            try leaf(3, "todo"),
            try leaf(4, "todo"),
            nested
        ])

        let summary = WorkbenchGroupSummary(group, showArchived: false)

        XCTAssertEqual(summary.done, 2)
        XCTAssertEqual(summary.total, 5, "the nested group itself is not counted, its leaves are")
        XCTAssertEqual(summary.breakdown, [
            .init(status: "todo", count: 2),
            .init(status: "in_progress", count: 1),
            .init(status: "done", count: 2)
        ], "board status order, statuses with zero omitted")
    }

    func testDismissedIsInTheBreakdownButNotInTheTotal() throws {
        let group = node(try target(1, "Group", status: "done"), [
            try leaf(2, "done"),
            try leaf(3, "dismissed")
        ])

        let summary = WorkbenchGroupSummary(group, showArchived: false)

        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(summary.total, 1, "a dismissed leaf is out of scope, not unfinished work (the lane rule)")
        XCTAssertEqual(summary.breakdown, [.init(status: "done", count: 1), .init(status: "dismissed", count: 1)])
    }

    func testArchivedLeavesFollowTheArchiveToggle() throws {
        let group = node(try target(1, "Group", status: "in_progress"), [
            try leaf(2, "done", archived: true),
            try leaf(3, "todo")
        ])

        let hidden = WorkbenchGroupSummary(group, showArchived: false)
        XCTAssertEqual(hidden.done, 0)
        XCTAssertEqual(hidden.total, 1)
        XCTAssertEqual(hidden.breakdown, [.init(status: "todo", count: 1)])

        let shown = WorkbenchGroupSummary(group, showArchived: true)
        XCTAssertEqual(shown.done, 1)
        XCTAssertEqual(shown.total, 2)
        XCTAssertEqual(shown.breakdown, [.init(status: "todo", count: 1), .init(status: "done", count: 1)])
    }

    func testAnUnknownStatusComesAfterTheBoardsOwn() throws {
        let group = node(try target(1, "Group", status: "in_progress"), [
            try leaf(2, "snoozed"),
            try leaf(3, "blocked")
        ])

        let summary = WorkbenchGroupSummary(group, showArchived: false)

        XCTAssertEqual(summary.breakdown, [.init(status: "blocked", count: 1), .init(status: "snoozed", count: 1)])
        XCTAssertEqual(summary.total, 2)
    }

    // MARK: - Sub-task tree

    func testClosedSubTasksFoldIntoOneRowAfterTheOpenOnes() throws {
        let group = node(try target(1, "Group", status: "in_progress"), [
            try leaf(2, "done"),
            try leaf(3, "todo"),
            try leaf(4, "dismissed"),
            try leaf(5, "in_progress")
        ])

        let folded = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [], showArchived: false)
        XCTAssertEqual(labels(folded), ["#3", "#5", "closed 2"])

        let unfolded = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [1], showArchived: false)
        XCTAssertEqual(labels(unfolded), ["#3", "#5", "closed 2 open", "#2", "#4"], "the fold opens in place")
    }

    func testNoClosedRowWhenNothingIsClosed() throws {
        let group = node(try target(1, "Group", status: "todo"), [try leaf(2, "todo")])

        let rows = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [], showArchived: false)

        XCTAssertEqual(labels(rows), ["#2"])
    }

    func testNestedGroupsNestAndFoldOnTheirOwn() throws {
        let nested = node(try target(10, "Nested", status: "in_progress"), [
            try leaf(11, "todo"),
            try leaf(12, "done")
        ])
        let group = node(try target(1, "Group", status: "in_progress"), [nested, try leaf(2, "todo")])

        let open = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [], showArchived: false)
        XCTAssertEqual(labels(open), ["#10", "  #11", "  closed 1", "#2"])
        guard case let .target(row) = open[0] else { return XCTFail("a target row first") }
        XCTAssertTrue(row.hasChildren)

        let collapsed = WorkbenchSubtaskTree.rows(of: group, collapsed: [10], unfoldedClosed: [], showArchived: false)
        XCTAssertEqual(labels(collapsed), ["#10", "#2"])
    }

    func testAClosedGroupWithAnOpenSubTaskStaysOpen() throws {
        let nested = node(try target(10, "Nested", status: "done"), [try leaf(11, "todo")])
        let group = node(try target(1, "Group", status: "in_progress"), [nested])

        let rows = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [], showArchived: false)

        XCTAssertEqual(labels(rows), ["#10", "  #11"], "folding the group would hide its open task")
    }

    func testArchivedSubTasksFollowTheArchiveToggle() throws {
        let group = node(try target(1, "Group", status: "in_progress"), [
            try leaf(2, "todo"),
            try leaf(3, "done", archived: true)
        ])

        let hidden = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [1], showArchived: false)
        XCTAssertEqual(labels(hidden), ["#2"])

        let shown = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [1], showArchived: true)
        XCTAssertEqual(labels(shown), ["#2", "closed 1 open", "#3"])
    }

    func testRowIDsAreUniqueAcrossTargetAndFoldRows() throws {
        let nested = node(try target(10, "Nested", status: "in_progress"), [try leaf(11, "done")])
        let group = node(try target(1, "Group", status: "in_progress"), [nested, try leaf(2, "done")])

        let rows = WorkbenchSubtaskTree.rows(of: group, collapsed: [], unfoldedClosed: [1, 10], showArchived: false)

        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}
