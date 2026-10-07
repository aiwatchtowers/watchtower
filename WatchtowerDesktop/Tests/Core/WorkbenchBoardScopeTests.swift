import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Entering a group at any depth (spec 2026-10-06 Part 4): the scope's
/// resolution and path, scoped Kanban lanes and columns, scoped List rows.
final class WorkbenchBoardScopeTests: XCTestCase {
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')")
        }
    }

    private func target(
        _ id: Int,
        _ text: String = "Task",
        status: String = "todo",
        priority: String = "medium"
    ) throws -> Target {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, level, custom_label, period_start, period_end,
                        status, priority, source_type, ownership, project_id)
                    VALUES (?, ?, 'custom', 'project', '2026-09-29', '2026-09-29', ?, ?, 'chat', 'mine', 1)
                    """,
                arguments: [id, text, status, priority]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = [], archived: Bool = false) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, archived: archived)
    }

    private func ids(_ board: WorkbenchBoardKanban, _ status: String) -> [Int] {
        board.columns.first { $0.status == status }?.cards.map(\.id) ?? []
    }

    private func laneIDs(_ lane: WorkbenchBoardKanban.Lane?, _ status: String) -> [Int] {
        lane?.columns.first { $0.status == status }?.cards.map(\.id) ?? []
    }

    /// 1 Plan › { 2 leaf, 3 Feature › { 4 leaf, 5 Step group › { 6 leaf, 7 leaf } }, 8 Epic › { 9 leaf } };
    /// 10 Other plan › { 11 leaf }; 12 lone leaf.
    private func tree() throws -> [WorkbenchBoardNode] {
        [
            node(try target(1, "Plan"), [
                node(try target(2, "Direct task")),
                node(try target(3, "Feature", priority: "low"), [
                    node(try target(4, "Feature task")),
                    node(try target(5, "Step group"), [node(try target(6, "Deep task")), node(try target(7, "Deep task two"))])
                ]),
                node(try target(8, "Epic", priority: "high"), [node(try target(9, "Epic task"))])
            ]),
            node(try target(10, "Other plan"), [node(try target(11, "Other task"))]),
            node(try target(12, "Lone leaf"))
        ]
    }

    // MARK: - Resolution

    func testATopLevelIDStoredByTheOldFilterResolvesTheSame() throws {
        let roots = try tree()
        let scope = WorkbenchBoardScope.resolve(1, in: roots, showArchived: false)
        XCTAssertEqual(scope.node?.target.id, 1)
        XCTAssertEqual(scope.path.map(\.target.id), [1])

        let board = WorkbenchBoardKanban(roots, scopeID: 1, showDone: false)
        XCTAssertEqual(board.scopeID, 1)
        XCTAssertEqual(ids(board, "todo"), [2, 4, 6, 7, 9], "the old filter's cards: the root's whole subtree")
    }

    func testADepthThreeGroupResolvesWithAThreeEntryPath() throws {
        let roots = try tree()
        let scope = WorkbenchBoardScope.resolve(5, in: roots, showArchived: false)
        XCTAssertEqual(scope.node?.target.id, 5)
        XCTAssertEqual(scope.path.map(\.target.id), [1, 3, 5])

        let board = WorkbenchBoardKanban(roots, scopeID: 5, showDone: false)
        XCTAssertEqual(board.scopeID, 5)
    }

    func testNilStaleOrLeafResolvesToTheBoardRoot() throws {
        let roots = try tree()
        for id in [nil, 999, 2, 12, 6] as [Int?] {
            let scope = WorkbenchBoardScope.resolve(id, in: roots, showArchived: true)
            XCTAssertNil(scope.node, "\(String(describing: id)) is not a group on this board")
            XCTAssertTrue(scope.path.isEmpty)
            let board = WorkbenchBoardKanban(roots, scopeID: id, showDone: false)
            XCTAssertNil(board.scopeID)
            XCTAssertEqual(ids(board, "todo"), [2, 4, 6, 7, 9, 11, 12])
        }
    }

    /// An archived scope — a top-level one or a group nested in one; an
    /// archived target's whole subtree is archived with it — is the board
    /// root while "Archive" is off; with it on, or with a search (which
    /// shows the archive), it applies.
    func testAnArchivedScopeAppliesOnlyWithArchiveOrASearch() throws {
        let roots = [
            node(try target(1, "Live"), [node(try target(2))]),
            node(try target(3, "Gone", status: "done"), [
                node(try target(4, "Sub", status: "done"), [node(try target(5, "Old", status: "done"), archived: true)],
                     archived: true)
            ], archived: true)
        ]
        for id in [3, 4] {
            XCTAssertNil(WorkbenchBoardScope.resolve(id, in: roots, showArchived: false).node, "#\(id), Archive off")
            XCTAssertEqual(WorkbenchBoardScope.resolve(id, in: roots, showArchived: true).node?.target.id, id)
            XCTAssertEqual(WorkbenchBoardScope.resolve(id, in: roots, showArchived: false, query: "old").node?.target.id, id)
        }
        XCTAssertEqual(WorkbenchBoardScope.resolve(4, in: roots, showArchived: true).path.map(\.target.id), [3, 4])

        let off = WorkbenchBoardKanban(roots, scopeID: 4, showDone: false)
        XCTAssertNil(off.scopeID)
        XCTAssertEqual(off.archivedCardCount, 1, "K counts what Archive on would show: the scope's #5")
        let on = WorkbenchBoardKanban(roots, scopeID: 4, showDone: false, showArchived: true)
        XCTAssertEqual(on.scopeID, 4)
        XCTAssertEqual(ids(on, "done"), [5])
        XCTAssertEqual(WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false, scopeID: 4).map(\.id), [1, 2],
                       "the List falls back to the whole board too")
    }

    // MARK: - Kanban in a scope

    /// Inside a scope its own leaf children are the first lane ("Tasks",
    /// root = the scope), each child with children a lane in
    /// `WorkbenchBoardOrder`; there is no No group lane; deeper levels are
    /// cards with a breadcrumb below their lane root.
    func testScopedLanesAreTheScopesTasksFirstThenItsGroupsInOrder() throws {
        let board = WorkbenchBoardKanban(try tree(), scopeID: 1, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [1, 8, 3])
        XCTAssertEqual(board.lanes.map(\.root?.target.id), [1, 8, 3])
        XCTAssertEqual(board.lanes.map(\.title), ["Tasks", "Epic", "Feature"])
        XCTAssertEqual(laneIDs(board.lanes.first, "todo"), [2])
        let feature = try XCTUnwrap(board.lanes.last)
        XCTAssertEqual(laneIDs(feature, "todo"), [4, 6, 7])
        XCTAssertEqual(feature.columns.first?.cards.map(\.breadcrumb), ["", "Step group", "Step group"])
        XCTAssertEqual(board.totals["todo"], 5)
        XCTAssertEqual(board.lanes.first?.progress, WorkbenchBoardKanban.Lane.Progress(done: 0, total: 1),
                       "the Tasks lane counts the scope's own leaves only")
    }

    func testTheTasksLaneIsThereOnlyWithOwnLeaves() throws {
        let roots = try tree()
        let board = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [3, 5], "#3 has the leaf #4, so Tasks; #5 a lane")
        let deep = WorkbenchBoardKanban(roots, scopeID: 10, showDone: false)
        XCTAssertEqual(deep.lanes.map(\.title), ["Tasks"])

        let groupsOnly = [node(try target(20, "Top"), [node(try target(21, "Group"), [node(try target(22))])])]
        let scoped = WorkbenchBoardKanban(groupsOnly, scopeID: 20, showDone: false)
        XCTAssertEqual(scoped.lanes.map(\.id), [21], "no own leaf, no Tasks lane")
    }

    /// "Lanes: None" in a top-level scope: the breadcrumb starts below the
    /// scope, so the scope's own name is never repeated on its cards.
    func testATopLevelScopesColumnsDropTheScopeFromTheBreadcrumb() throws {
        let board = WorkbenchBoardKanban(try tree(), scopeID: 1, showDone: false)
        let todo = try XCTUnwrap(board.columns.first { $0.status == "todo" })
        XCTAssertEqual(todo.cards.map(\.id), [2, 4, 6, 7, 9])
        XCTAssertEqual(todo.cards.map(\.breadcrumb),
                       ["", "Feature", "Feature › Step group", "Feature › Step group", "Epic"])
    }

    /// The Tasks lane follows the lane rule with the scope as its root: an
    /// open scope keeps it with nothing left to show ("No open tasks"); a
    /// closed one hides it until Show done.
    func testTheTasksLaneHidesOnlyForAClosedScope() throws {
        let open = [
            node(try target(20, "Open scope"), [
                node(try target(21, status: "done")),
                node(try target(22, "Group"), [node(try target(23))])
            ])
        ]
        let openBoard = WorkbenchBoardKanban(open, scopeID: 20, showDone: false)
        XCTAssertEqual(openBoard.lanes.map(\.title), ["Tasks", "Group"])
        let tasks = try XCTUnwrap(openBoard.lanes.first)
        XCTAssertTrue(tasks.columns.allSatisfy { tasks.cards($0, unfolded: false).isEmpty })
        XCTAssertEqual(tasks.doneCount, 1)

        let closed = [
            node(try target(30, "Closed scope", status: "done"), [
                node(try target(31, status: "done")),
                node(try target(32, "Group", status: "done"), [node(try target(33, status: "done"))])
            ])
        ]
        XCTAssertEqual(WorkbenchBoardKanban(closed, scopeID: 30, showDone: false).lanes.map(\.id), [])
        XCTAssertEqual(WorkbenchBoardKanban(closed, scopeID: 30, showDone: true).lanes.map(\.id), [30, 32])
    }

    func testScopedColumnsHoldTheScopesLeavesWithBreadcrumbsBelowIt() throws {
        let board = WorkbenchBoardKanban(try tree(), scopeID: 3, showDone: false)
        let todo = try XCTUnwrap(board.columns.first { $0.status == "todo" })
        XCTAssertEqual(todo.cards.map(\.id), [4, 6, 7])
        XCTAssertEqual(todo.cards.map(\.breadcrumb), ["", "Step group", "Step group"])
        XCTAssertFalse(board.showsCard(2), "a card outside the scope is not on this board")
    }

    /// A search inside a scope never reaches outside it, and keeps what the
    /// same search on the whole board keeps there: a match on the scope or
    /// an ancestor keeps every leaf below.
    func testASearchInsideAScopeStaysInside() throws {
        let roots = try tree()
        let deep = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false, query: "task")
        XCTAssertEqual(ids(deep, "todo"), [4, 6, 7])
        XCTAssertEqual(deep.scopeID, 3)
        XCTAssertEqual(ids(WorkbenchBoardKanban(roots, scopeID: 3, showDone: false, query: "#11"), "todo"), [])
        XCTAssertEqual(ids(WorkbenchBoardKanban(roots, scopeID: 3, showDone: false, query: "two"), "todo"), [7])
        XCTAssertEqual(ids(WorkbenchBoardKanban(roots, scopeID: 5, showDone: false, query: "plan"), "todo"), [6, 7],
                       "the ancestor #1 matches: the scope's whole subtree")

        let rows = WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false, query: "task", scopeID: 3)
        XCTAssertEqual(rows.map(\.id), [4, 5, 6, 7])
        XCTAssertEqual(WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false, query: "#11", scopeID: 3).map(\.id), [])
        XCTAssertEqual(WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false, query: "plan", scopeID: 5).map(\.id),
                       [6, 7])
    }

    // MARK: - List in a scope

    func testScopedListRowsStartAtTheScopesChildren() throws {
        let roots = try tree()
        let rows = WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false, scopeID: 3)
        XCTAssertEqual(rows.map(\.id), [4, 5, 6, 7])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertEqual(WorkbenchBoardOutline.rows(roots, collapsed: [5], showDone: false, scopeID: 3).map(\.id), [4, 5])
        XCTAssertEqual(WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false, scopeID: 12).map(\.id),
                       WorkbenchBoardOutline.rows(roots, collapsed: [], showDone: false).map(\.id),
                       "a leaf is no scope: the whole board")
    }
}
