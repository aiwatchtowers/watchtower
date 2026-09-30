import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectBoardCardTests: XCTestCase {

    // Real Target rows through the DB, so the fixture never drifts from
    // Target's own row decoding.
    private func target(
        _ id: Int,
        _ text: String = "Task",
        status: String = "todo",
        priority: String = "medium",
        progress: Double = 0
    ) throws -> Target {
        let queue = try TestDatabase.create()
        return try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, priority, progress, source_type, ownership)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, ?, 'chat', 'mine')
                    """,
                arguments: [id, text, status, priority, progress]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [ProjectBoardNode] = []) -> ProjectBoardNode {
        ProjectBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, documents: [])
    }

    // MARK: - Order (Go boardSiblingOrder)

    func testOrderIsPriorityThenStatusThenID() throws {
        let targets = [
            try target(1, status: "in_progress", priority: "low"),
            try target(2, status: "done", priority: "high"),
            try target(3, status: "todo", priority: "high"),
            try target(4, status: "blocked", priority: "medium"),
            try target(5, status: "in_progress", priority: "medium"),
            try target(6, status: "dismissed", priority: "high"),
            try target(7, status: "todo", priority: "high")
        ]
        XCTAssertEqual(ProjectBoardOrder.sorted(targets.shuffled()).map(\.id), [3, 7, 2, 6, 5, 4, 1])
    }

    func testRanksMatchGoCaseArms() {
        XCTAssertEqual(["high", "medium", "low", "bogus"].map(ProjectBoardOrder.priorityRank), [0, 1, 2, 2])
        XCTAssertEqual(
            ["in_progress", "blocked", "todo", "done", "dismissed", "snoozed"].map(ProjectBoardOrder.statusRank),
            [0, 1, 2, 3, 4, 4]
        )
    }

    // MARK: - Card

    func testParentCountsDoneChildrenAndIgnoresDismissed() throws {
        let card = ProjectBoardCard(node(try target(1, "Feature"), [
            node(try target(2, status: "done")),
            node(try target(3, status: "in_progress")),
            node(try target(4, status: "dismissed"))
        ]))
        XCTAssertEqual(card.children, .init(done: 1, total: 2))
        XCTAssertEqual(card.children?.fraction, 0.5)
        XCTAssertNil(card.leafProgress, "a parent shows its children, not its own progress")
    }

    func testParentWithOnlyDismissedChildrenHasZeroTotal() throws {
        let card = ProjectBoardCard(node(try target(1), [node(try target(2, status: "dismissed"))]))
        XCTAssertEqual(card.children, .init(done: 0, total: 0))
        XCTAssertEqual(card.children?.fraction, 0)
    }

    func testLeafShowsOnlyPartialProgress() throws {
        XCTAssertEqual(ProjectBoardCard(node(try target(1, progress: 0.4))).leafProgress, 0.4)
        XCTAssertNil(ProjectBoardCard(node(try target(2, progress: 0))).leafProgress)
        XCTAssertNil(ProjectBoardCard(node(try target(3, progress: 1))).leafProgress)
        XCTAssertNil(ProjectBoardCard(node(try target(4))).children)
    }

    func testClosedAndDoneFlags() throws {
        let done = ProjectBoardCard(node(try target(1, status: "done")))
        let dismissed = ProjectBoardCard(node(try target(2, status: "dismissed")))
        let blocked = ProjectBoardCard(node(try target(3, status: "blocked")))
        XCTAssertEqual([done.isClosed, done.isDone], [true, true])
        XCTAssertEqual([dismissed.isClosed, dismissed.isDone], [true, false])
        XCTAssertEqual([blocked.isClosed, blocked.isDone], [false, false])
    }

    func testTitleIsFirstNonBlankLine() {
        XCTAssertEqual(ProjectBoardCard.title("\n  \n  Ship it  \nDetails"), "Ship it")
        XCTAssertEqual(ProjectBoardCard.title("One"), "One")
        XCTAssertEqual(ProjectBoardCard.title(" \n "), "")
    }

    func testStatusLabels() {
        XCTAssertEqual(
            ProjectBoardCard.editableStatuses.map(ProjectBoardCard.statusLabel),
            ["To Do", "In Progress", "Blocked", "Done", "Dismissed"]
        )
        XCTAssertEqual(ProjectBoardCard.statusLabel("in_review"), "In Review")
        XCTAssertEqual(ProjectBoardCard.statusLabel("waiting_on_vendor"), "waiting_on_vendor", "unknown = raw text")
    }

    func testStatusTints() {
        XCTAssertEqual(
            ["todo", "in_progress", "in_review", "blocked", "done", "dismissed", "waiting_on_vendor"]
                .map(ProjectBoardCard.statusTint),
            ["secondary", "blue", "teal", "red", "green", "gray", "secondary"]
        )
    }
}
