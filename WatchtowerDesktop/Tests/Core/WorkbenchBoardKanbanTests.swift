import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchBoardKanbanTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
        // in_review is a project-only status (CHECK), so every fixture target
        // lives on project 1.
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')")
        }
    }

    // Real Target rows through the DB, so the fixture never drifts from
    // Target's own row decoding.
    private func target(
        _ id: Int,
        _ text: String = "Task",
        status: String = "todo",
        priority: String = "medium",
        updatedAt: String = "2026-09-29T10:00:00Z"
    ) throws -> Target {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, priority, source_type, ownership, updated_at, project_id)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, 'chat', 'mine', ?, 1)
                    """,
                arguments: [id, text, status, priority, updatedAt]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = []) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0)
    }

    private func column(_ board: WorkbenchBoardKanban, _ status: String) -> WorkbenchBoardKanban.Column? {
        board.columns.first { $0.status == status }
    }

    private func ids(_ board: WorkbenchBoardKanban, _ status: String) -> [Int] {
        column(board, status)?.cards.map(\.id) ?? []
    }

    // MARK: - Columns

    func testLeavesLandInTheirStatusColumnsAndParentsNeverDo() throws {
        let roots = [
            node(try target(1, "Plan", status: "in_progress"), [
                node(try target(2, status: "todo")),
                node(try target(3, "Feature", status: "in_progress"), [
                    node(try target(4, status: "in_progress")),
                    node(try target(5, status: "in_review")),
                    node(try target(6, status: "blocked"))
                ])
            ]),
            node(try target(7, status: "done"))
        ]
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)

        XCTAssertEqual(board.columns.map(\.status), ["todo", "in_progress", "in_review", "blocked", "done"])
        XCTAssertEqual(board.columns.map(\.title), ["To Do", "In Progress", "In Review", "Blocked", "Done"])
        XCTAssertEqual(ids(board, "todo"), [2])
        XCTAssertEqual(ids(board, "in_progress"), [4], "parents 1 and 3 are never cards")
        XCTAssertEqual(ids(board, "in_review"), [5])
        XCTAssertEqual(ids(board, "blocked"), [6])
        XCTAssertEqual(ids(board, "done"), [7])
    }

    func testSearchKeepsMatchingLeavesAndLeavesUnderAMatchingParent() throws {
        let roots = [
            node(try target(1, "Comments group"), [
                node(try target(2, "Artifact comments")),
                node(try target(3, "Document comments", status: "dismissed"))
            ]),
            node(try target(4, "Widget")),
            node(try target(5, "Artifact viewer", status: "done"))
        ]
        let byGroup = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false, query: "#1")
        XCTAssertEqual(ids(byGroup, "todo"), [2])
        XCTAssertEqual(ids(byGroup, "dismissed"), [3], "a search shows dismissed cards as Show done would")
        let byText = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false, query: "artifact")
        XCTAssertEqual(ids(byText, "todo"), [2])
        XCTAssertEqual(ids(byText, "done"), [5])
        XCTAssertFalse(byText.showsCard(4))
    }

    func testColumnOrderIsPriorityThenID() throws {
        let roots = [
            node(try target(1, priority: "low")),
            node(try target(2, priority: "high")),
            node(try target(3, priority: "medium")),
            node(try target(4, priority: "high"))
        ]
        let board = WorkbenchBoardKanban(roots.shuffled(), filterRootID: nil, showDone: false)
        XCTAssertEqual(ids(board, "todo"), [2, 4, 3, 1])
    }

    func testBreadcrumbIsTheParentChain() throws {
        let roots = [
            node(try target(1, "Polish the Projects page UI\nmore text"), [
                node(try target(2, "Sub-parent"), [node(try target(3, "Leaf"))])
            ]),
            node(try target(4, "Top-level leaf"))
        ]
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)
        let cards = try XCTUnwrap(column(board, "todo")).cards
        XCTAssertEqual(cards.map(\.id), [3, 4])
        XCTAssertEqual(cards.map(\.breadcrumb), ["Polish the Projects page UI › Sub-parent", ""])
    }

    func testEmptyBoardHasTheFiveEmptyColumnsAndNoFilterOptions() {
        let board = WorkbenchBoardKanban([], filterRootID: nil, showDone: false)
        XCTAssertEqual(board.columns.map(\.status), ["todo", "in_progress", "in_review", "blocked", "done"])
        XCTAssertTrue(board.columns.allSatisfy { $0.cards.isEmpty && $0.hiddenCount == 0 })
        XCTAssertTrue(board.filterOptions.isEmpty)
    }

    // MARK: - Done / Dismissed

    func testShowDoneOffCapsDoneAtTheTenMostRecentAndHidesDismissed() throws {
        // 12 done leaves, updated one minute apart: 101 is the oldest.
        var roots = try (0..<12).map { i in
            node(try target(101 + i, status: "done", updatedAt: String(format: "2026-09-29T10:%02d:00Z", i)))
        }
        roots.append(node(try target(200, status: "dismissed")))
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)

        let done = try XCTUnwrap(column(board, "done"))
        XCTAssertEqual(done.cards.map(\.id), Array((103...112).reversed()), "most recently updated first")
        XCTAssertEqual(done.hiddenCount, 2)
        XCTAssertEqual(board.columns.map(\.status), ["todo", "in_progress", "in_review", "blocked", "done"],
                       "a dismissed leaf is hidden, never moved into Other")
    }

    func testDoneCapBoundary() throws {
        let ten = try (0..<10).map { node(try target(101 + $0, status: "done")) }
        XCTAssertEqual(column(WorkbenchBoardKanban(ten, filterRootID: nil, showDone: false), "done")?.hiddenCount, 0)
        let eleven = ten + [node(try target(111, status: "done"))]
        let done = column(WorkbenchBoardKanban(eleven, filterRootID: nil, showDone: false), "done")
        XCTAssertEqual(done?.cards.count, 10)
        XCTAssertEqual(done?.hiddenCount, 1)
    }

    func testShowDoneOnShowsEveryDoneCardAndTheDismissedColumn() throws {
        var roots = try (0..<12).map { i in
            node(try target(101 + i, status: "done", updatedAt: String(format: "2026-09-29T10:%02d:00Z", i)))
        }
        roots.append(node(try target(200, status: "dismissed")))
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: true)

        XCTAssertEqual(board.columns.map(\.status), ["todo", "in_progress", "in_review", "blocked", "done", "dismissed"])
        XCTAssertEqual(column(board, "done")?.cards.count, 12)
        XCTAssertEqual(column(board, "done")?.hiddenCount, 0)
        XCTAssertEqual(ids(board, "dismissed"), [200])
    }

    func testDoneTiesOnUpdatedAtBreakByNewestID() throws {
        let roots = [
            node(try target(1, status: "done")),
            node(try target(2, status: "done"))
        ]
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)
        XCTAssertEqual(ids(board, "done"), [2, 1])
    }

    // MARK: - Drop acceptance

    /// The drop payload is plain text: only a card shown on this board may move.
    func testShowsCardOnlyForShownLeaves() throws {
        var roots = [node(try target(1, "Plan"), [node(try target(2))])]
        // 11 done leaves, 101 the oldest: it falls past the cap.
        roots += try (0..<11).map { i in
            node(try target(101 + i, status: "done", updatedAt: String(format: "2026-09-29T10:%02d:00Z", i)))
        }
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)
        XCTAssertTrue(board.showsCard(2))
        XCTAssertTrue(board.showsCard(111))
        XCTAssertFalse(board.showsCard(1), "a parent is never a card")
        XCTAssertFalse(board.showsCard(999))
        XCTAssertFalse(board.showsCard(101), "a done card past the cap is not on screen, so not droppable")
    }

    // MARK: - Other

    func testUnknownStatusGoesToAnOtherColumnOnlyWhenPresent() throws {
        let known = WorkbenchBoardKanban([node(try target(1))], filterRootID: nil, showDone: true)
        XCTAssertNil(column(known, WorkbenchBoardKanban.otherStatus))

        let roots = [
            node(try target(2, status: "snoozed")),
            // A newer CLI's status the CHECK here does not know: decoded
            // straight from a row, the way a newer database would hand it over.
            node(Target(row: Row(["id": 3, "text": "Future", "status": "someday", "priority": "medium"])))
        ]
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)
        let other = try XCTUnwrap(board.columns.last)
        XCTAssertEqual(other.status, WorkbenchBoardKanban.otherStatus)
        XCTAssertEqual(other.title, "Other")
        XCTAssertFalse(other.acceptsDrops)
        XCTAssertEqual(other.cards.map(\.id), [2, 3])
        XCTAssertTrue(board.columns.dropLast().allSatisfy(\.acceptsDrops))
    }

    // MARK: - Parent filter

    func testFilterKeepsOnlyThatRootsSubtree() throws {
        let roots = [
            node(try target(1, "Plan A"), [node(try target(2)), node(try target(3), [node(try target(4))])]),
            node(try target(5, "Plan B"), [node(try target(6))]),
            node(try target(7, "Lone leaf"))
        ]
        let all = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)
        XCTAssertEqual(ids(all, "todo"), [2, 4, 6, 7])
        XCTAssertNil(all.filterRootID)

        let filtered = WorkbenchBoardKanban(roots, filterRootID: 1, showDone: false)
        XCTAssertEqual(ids(filtered, "todo"), [2, 4])
        XCTAssertEqual(filtered.filterRootID, 1)
    }

    /// A top-level leaf is its own card under All; it is not a filter option
    /// (a "subtree" of one card is not worth a menu entry).
    func testFilterOptionsAreTopLevelTargetsWithLeaves() throws {
        let roots = [
            node(try target(1, "Plan A\nbody"), [node(try target(2))]),
            node(try target(3, "Lone leaf")),
            node(try target(4, "Plan B"), [node(try target(5))])
        ]
        let board = WorkbenchBoardKanban(roots, filterRootID: nil, showDone: false)
        XCTAssertEqual(board.filterOptions.map(\.id), [1, 4])
        XCTAssertEqual(board.filterOptions.map(\.title), ["Plan A", "Plan B"])
    }

    func testStaleOrNonOptionFilterFallsBackToAll() throws {
        let roots = [
            node(try target(1, "Plan A"), [node(try target(2))]),
            node(try target(3, "Lone leaf"))
        ]
        for stale in [999, 3, 2] {
            let board = WorkbenchBoardKanban(roots, filterRootID: stale, showDone: false)
            XCTAssertNil(board.filterRootID, "filter \(stale) is not an option")
            XCTAssertEqual(ids(board, "todo"), [2, 3])
        }
    }

    // MARK: - Preferences

    func testPreferencesArePerProjectAndDefaultToListAndAll() throws {
        let suite = "WorkbenchBoardKanbanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let one = WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults)
        XCTAssertEqual(one.mode, .list)
        XCTAssertNil(one.kanbanFilterRootID)

        one.mode = .kanban
        one.kanbanFilterRootID = 42
        XCTAssertEqual(defaults.string(forKey: "projects.boardMode.1"), "kanban")
        XCTAssertEqual(defaults.integer(forKey: "projects.boardKanbanFilter.1"), 42)

        let reread = WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults)
        XCTAssertEqual(reread.mode, .kanban)
        XCTAssertEqual(reread.kanbanFilterRootID, 42)

        let two = WorkbenchBoardPreferences(workbenchID: 2, defaults: defaults)
        XCTAssertEqual(two.mode, .list)
        XCTAssertNil(two.kanbanFilterRootID)

        one.kanbanFilterRootID = nil
        XCTAssertNil(defaults.object(forKey: "projects.boardKanbanFilter.1"))
        defaults.set("bogus", forKey: "projects.boardMode.1")
        XCTAssertEqual(WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults).mode, .list)
    }
}
