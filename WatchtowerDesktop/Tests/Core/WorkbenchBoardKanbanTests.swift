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

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = [], archived: Bool = false) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, archived: archived)
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
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)

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
        let byGroup = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, query: "#1")
        XCTAssertEqual(ids(byGroup, "todo"), [2])
        XCTAssertEqual(ids(byGroup, "dismissed"), [3], "a search shows dismissed cards as Show done would")
        let byText = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, query: "artifact")
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
        let board = WorkbenchBoardKanban(roots.shuffled(), scopeID: nil, showDone: false)
        XCTAssertEqual(ids(board, "todo"), [2, 4, 3, 1])
    }

    func testBreadcrumbIsTheParentChain() throws {
        let roots = [
            node(try target(1, "Polish the Projects page UI\nmore text"), [
                node(try target(2, "Sub-parent"), [node(try target(3, "Leaf"))])
            ]),
            node(try target(4, "Top-level leaf"))
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        let cards = try XCTUnwrap(column(board, "todo")).cards
        XCTAssertEqual(cards.map(\.id), [3, 4])
        XCTAssertEqual(cards.map(\.breadcrumb), ["Polish the Projects page UI › Sub-parent", ""])
    }

    func testEmptyBoardHasTheFiveEmptyColumnsAndNoScope() {
        let board = WorkbenchBoardKanban([], scopeID: nil, showDone: false)
        XCTAssertEqual(board.columns.map(\.status), ["todo", "in_progress", "in_review", "blocked", "done"])
        XCTAssertTrue(board.columns.allSatisfy { $0.cards.isEmpty && $0.hiddenCount == 0 })
        XCTAssertNil(board.scopeID)
        XCTAssertTrue(board.scopePath.isEmpty)
    }

    // MARK: - Done / Dismissed

    func testShowDoneOffCapsDoneAtTheTenMostRecentAndHidesDismissed() throws {
        // 12 done leaves, updated one minute apart: 101 is the oldest.
        var roots = try (0..<12).map { i in
            node(try target(101 + i, status: "done", updatedAt: String(format: "2026-09-29T10:%02d:00Z", i)))
        }
        roots.append(node(try target(200, status: "dismissed")))
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)

        let done = try XCTUnwrap(column(board, "done"))
        XCTAssertEqual(done.cards.map(\.id), Array((103...112).reversed()), "most recently updated first")
        XCTAssertEqual(done.hiddenCount, 2)
        XCTAssertEqual(board.columns.map(\.status), ["todo", "in_progress", "in_review", "blocked", "done"],
                       "a dismissed leaf is hidden, never moved into Other")
    }

    func testDoneCapBoundary() throws {
        let ten = try (0..<10).map { node(try target(101 + $0, status: "done")) }
        XCTAssertEqual(column(WorkbenchBoardKanban(ten, scopeID: nil, showDone: false), "done")?.hiddenCount, 0)
        let eleven = ten + [node(try target(111, status: "done"))]
        let done = column(WorkbenchBoardKanban(eleven, scopeID: nil, showDone: false), "done")
        XCTAssertEqual(done?.cards.count, 10)
        XCTAssertEqual(done?.hiddenCount, 1)
    }

    func testShowDoneOnShowsEveryDoneCardAndTheDismissedColumn() throws {
        var roots = try (0..<12).map { i in
            node(try target(101 + i, status: "done", updatedAt: String(format: "2026-09-29T10:%02d:00Z", i)))
        }
        roots.append(node(try target(200, status: "dismissed")))
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: true)

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
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
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
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertTrue(board.showsCard(2))
        XCTAssertTrue(board.showsCard(111))
        XCTAssertFalse(board.showsCard(1), "a parent is never a card")
        XCTAssertFalse(board.showsCard(999))
        XCTAssertFalse(board.showsCard(101), "a done card past the cap is not on screen, so not droppable")
    }

    // MARK: - Other

    func testUnknownStatusGoesToAnOtherColumnOnlyWhenPresent() throws {
        let known = WorkbenchBoardKanban([node(try target(1))], scopeID: nil, showDone: true)
        XCTAssertNil(column(known, WorkbenchBoardKanban.otherStatus))

        let roots = [
            node(try target(2, status: "snoozed")),
            // A newer CLI's status the CHECK here does not know: decoded
            // straight from a row, the way a newer database would hand it over.
            node(Target(row: Row(["id": 3, "text": "Future", "status": "someday", "priority": "medium"])))
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
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
        let all = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(ids(all, "todo"), [2, 4, 6, 7])
        XCTAssertNil(all.scopeID)

        let filtered = WorkbenchBoardKanban(roots, scopeID: 1, showDone: false)
        XCTAssertEqual(ids(filtered, "todo"), [2, 4])
        XCTAssertEqual(filtered.scopeID, 1)
    }

    func testStaleOrNonOptionFilterFallsBackToAll() throws {
        let roots = [
            node(try target(1, "Plan A"), [node(try target(2))]),
            node(try target(3, "Lone leaf"))
        ]
        for stale in [999, 3, 2] {
            let board = WorkbenchBoardKanban(roots, scopeID: stale, showDone: false)
            XCTAssertNil(board.scopeID, "filter \(stale) is not an option")
            XCTAssertEqual(ids(board, "todo"), [2, 3])
        }
    }

    // MARK: - Archive (board #301)

    /// 12 live done leaves (101 oldest), live dismissed 200, archived done
    /// 300–302 and archived dismissed 400 — the archived ones older still.
    private func archiveRoots() throws -> [WorkbenchBoardNode] {
        var roots = try (0..<12).map { i in
            node(try target(101 + i, status: "done", updatedAt: String(format: "2026-09-29T10:%02d:00Z", i)))
        }
        roots.append(node(try target(200, status: "dismissed")))
        roots += try (0..<3).map { i in
            node(try target(300 + i, "Old", status: "done", updatedAt: "2026-08-0\(i + 1)T10:00:00Z"), archived: true)
        }
        roots.append(node(try target(400, "Old", status: "dismissed", updatedAt: "2026-08-01T10:00:00Z"), archived: true))
        return roots
    }

    func testArchivedLeavesAreCardsOnlyWithTheToggle() throws {
        let roots = try archiveRoots()
        let off = WorkbenchBoardKanban(roots, scopeID: nil, showDone: true)
        XCTAssertEqual(ids(off, "done"), Array((101...112).reversed()))
        XCTAssertEqual(ids(off, "dismissed"), [200])
        XCTAssertFalse(off.showsCard(300))

        let on = WorkbenchBoardKanban(roots, scopeID: nil, showDone: true, showArchived: true)
        XCTAssertEqual(ids(on, "done"), Array((101...112).reversed()) + [302, 301, 300])
        XCTAssertEqual(ids(on, "dismissed"), [200, 400])
    }

    func testArchivedDoneCardsAreNeverCappedAndDismissedHoldsOnlyArchivedWithoutShowDone() throws {
        let board = WorkbenchBoardKanban(try archiveRoots(), scopeID: nil, showDone: false, showArchived: true)
        let done = try XCTUnwrap(column(board, "done"))
        XCTAssertEqual(done.cards.map(\.id), Array((103...112).reversed()) + [302, 301, 300],
                       "the cap trims live done cards only")
        XCTAssertEqual(done.hiddenCount, 2)
        XCTAssertEqual(ids(board, "dismissed"), [400], "a live dismissed card still waits for Show done")
    }

    func testSearchShowsArchivedLeaves() throws {
        let board = WorkbenchBoardKanban(try archiveRoots(), scopeID: nil, showDone: false, query: "old")
        XCTAssertEqual(ids(board, "done"), [302, 301, 300])
        XCTAssertEqual(ids(board, "dismissed"), [400])
    }

    func testAnArchivedRootScopesOnlyWithTheToggle() throws {
        let roots = [
            node(try target(1, "Live"), [node(try target(2))]),
            node(try target(3, "Gone", status: "done"), [node(try target(4, status: "done"), archived: true)], archived: true)
        ]
        let off = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false)
        XCTAssertNil(off.scopeID, "a filter on an archived group shows All while the archive is hidden")
        let on = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false, showArchived: true)
        XCTAssertEqual(on.scopeID, 3)
        XCTAssertEqual(ids(on, "done"), [4])
    }

    /// Kanban's "Archive (K)" counts the archived leaf cards under the
    /// filter: never an archived group, never another root's leaves, and
    /// the same whatever the toggles and the search.
    func testArchivedCardCountIsTheArchivedLeavesUnderTheFilter() throws {
        let roots = [
            node(try target(1, "Live"), [node(try target(2)), node(try target(5, status: "done"), archived: true)]),
            node(try target(3, "Gone", status: "done"), [
                node(try target(4, status: "done"), archived: true),
                node(try target(6, status: "dismissed"), archived: true)
            ], archived: true)
        ]
        let all = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(all.archivedCardCount, 3, "#5, #4, #6, not the group #3")
        let on = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, showArchived: true)
        XCTAssertEqual(on.archivedCardCount, 3)
        XCTAssertEqual(on.columns.flatMap(\.cards).filter(\.node.archived).count, 3, "the toggle adds exactly K cards")
        let live = WorkbenchBoardKanban(roots, scopeID: 1, showDone: false, showArchived: true, query: "zzz")
        XCTAssertEqual(live.archivedCardCount, 1, "only #5 under the Live filter")
    }

    /// A remembered filter on an archived root shows All while "Archive"
    /// is off, but K already counts that root only: what turning it on adds.
    func testArchivedCardCountFollowsARememberedArchivedRootFilter() throws {
        let roots = [
            node(try target(1, "Live"), [node(try target(2)), node(try target(5, status: "done"), archived: true)]),
            node(try target(3, "Gone", status: "done"), [
                node(try target(4, status: "done"), archived: true),
                node(try target(6, status: "dismissed"), archived: true)
            ], archived: true)
        ]
        let off = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false)
        XCTAssertNil(off.scopeID, "precondition: the filter shows All while the archive is hidden")
        XCTAssertEqual(off.archivedCardCount, 2, "#4 and #6, not #5 under another root")
        let on = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false, showArchived: true)
        XCTAssertEqual(on.columns.flatMap(\.cards).filter(\.node.archived).count, off.archivedCardCount)
    }

    func testArchivedCardCountOnABoardWithoutArchive() throws {
        let board = WorkbenchBoardKanban([node(try target(1))], scopeID: nil, showDone: false)
        XCTAssertEqual(board.archivedCardCount, 0)
        XCTAssertEqual(WorkbenchBoardKanban([], scopeID: nil, showDone: false).archivedCardCount, 0)
    }

    // MARK: - Lanes (spec 2026-10-06 Part 2)

    private func lane(_ board: WorkbenchBoardKanban, _ id: Int) -> WorkbenchBoardKanban.Lane? {
        board.lanes.first { $0.id == id }
    }

    private func laneIDs(_ lane: WorkbenchBoardKanban.Lane?, _ status: String) -> [Int] {
        lane?.columns.first { $0.status == status }?.cards.map(\.id) ?? []
    }

    func testEachTopLevelGroupIsALaneAndTopLevelLeavesGoToNoGroupLast() throws {
        let roots = [
            node(try target(1, "Plan A"), [node(try target(2))]),
            node(try target(3, "Lone leaf")),
            node(try target(4, "Plan B\nbody"), [node(try target(5, status: "in_progress"))])
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [1, 4, 0])
        XCTAssertEqual(board.lanes.map(\.root?.target.id), [1, 4, nil])
        XCTAssertEqual(board.lanes.map(\.title), ["Plan A", "Plan B", "No group"])
        XCTAssertEqual(laneIDs(board.lanes.last, "todo"), [3])
        XCTAssertEqual(laneIDs(lane(board, 4), "in_progress"), [5])
        XCTAssertEqual(board.lanes.map { $0.columns.map(\.status) },
                       Array(repeating: board.columns.map(\.status), count: 3),
                       "every lane has the board's columns, so the totals row heads them all")

        let noLeaf = WorkbenchBoardKanban(Array(roots.filter { $0.target.id != 3 }), scopeID: nil, showDone: false)
        XCTAssertEqual(noLeaf.lanes.map(\.id), [1, 4], "no top-level leaf, no No group lane")
    }

    func testLaneOrderIsPriorityThenStatusThenID() throws {
        let roots = [
            node(try target(1, priority: "medium"), [node(try target(11))]),
            node(try target(2, status: "in_progress", priority: "medium"), [node(try target(12))]),
            node(try target(3, priority: "high"), [node(try target(13))]),
            node(try target(4, priority: "medium"), [node(try target(14))]),
            node(try target(5, priority: "low"), [node(try target(15))])
        ]
        let board = WorkbenchBoardKanban(roots.shuffled(), scopeID: nil, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [3, 2, 1, 4, 5])
    }

    func testLaneBreadcrumbIsTheChainBelowTheLaneRoot() throws {
        let roots = [
            node(try target(1, "Plan"), [
                node(try target(2, "Direct leaf")),
                node(try target(3, "Middle group"), [node(try target(4, "Deep leaf"))])
            ]),
            node(try target(5, "Lone leaf"))
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        let cards = try XCTUnwrap(lane(board, 1)?.columns.first { $0.status == "todo" }).cards
        XCTAssertEqual(cards.map(\.id), [2, 4])
        XCTAssertEqual(cards.map(\.breadcrumb), ["", "Middle group"])
        XCTAssertEqual(board.lanes.last?.columns.first?.cards.map(\.breadcrumb), [""])
    }

    func testANestedGroupIsCardsInItsTopLevelLaneNeverALane() throws {
        let roots = [
            node(try target(1, "Plan"), [
                node(try target(2, "Nested"), [node(try target(3)), node(try target(4))])
            ])
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [1])
        XCTAssertEqual(laneIDs(lane(board, 1), "todo"), [3, 4])
    }

    func testLaneDoneIsFoldedWithItsCountUnlessShowDoneOrASearch() throws {
        let roots = [
            node(try target(1, "Plan", status: "in_progress"), [
                node(try target(2, "Open")),
                node(try target(3, "Closed", status: "done")),
                node(try target(4, "Closed", status: "done"))
            ])
        ]
        let folded = try XCTUnwrap(lane(WorkbenchBoardKanban(roots, scopeID: nil, showDone: false), 1))
        XCTAssertTrue(folded.doneFolded)
        XCTAssertEqual(folded.doneCount, 2)
        XCTAssertEqual(laneIDs(folded, "done"), [4, 3], "folding is the view's: the cards stay, never capped")
        let doneColumn = try XCTUnwrap(folded.columns.first { $0.status == "done" })
        XCTAssertEqual(folded.cards(doneColumn, unfolded: false).map(\.id), [])
        XCTAssertEqual(folded.cards(doneColumn, unfolded: true).map(\.id), [4, 3])

        let shown = try XCTUnwrap(lane(WorkbenchBoardKanban(roots, scopeID: nil, showDone: true), 1))
        XCTAssertFalse(shown.doneFolded)
        XCTAssertEqual(shown.doneCount, 2)
        XCTAssertEqual(shown.cards(doneColumn, unfolded: false).map(\.id), [4, 3])

        let searched = try XCTUnwrap(lane(WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, query: "closed"), 1))
        XCTAssertFalse(searched.doneFolded)
        XCTAssertEqual(laneIDs(searched, "done"), [4, 3])
    }

    /// The fold stands for the live done cards; archived ones are never
    /// folded, as the None layout's cap never trims them.
    func testArchivedDoneCardsStayOutOfTheLaneFold() throws {
        let roots = [
            node(try target(1, "Plan", status: "in_progress"), [
                node(try target(2)),
                node(try target(3, status: "done")),
                node(try target(4, status: "done", updatedAt: "2026-08-01T10:00:00Z"), archived: true)
            ])
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, showArchived: true)
        let l = try XCTUnwrap(lane(board, 1))
        let done = try XCTUnwrap(l.columns.first { $0.status == "done" })
        XCTAssertEqual(l.doneCount, 1)
        XCTAssertEqual(l.cards(done, unfolded: false).map(\.id), [4])
        XCTAssertEqual(l.cards(done, unfolded: true).map(\.id), [3, 4])
    }

    /// A status this build does not know lands in the lane's Other column,
    /// present on every lane once any card needs it (the totals row heads
    /// them all), refusing drops like the None layout's.
    func testAnUnknownStatusGoesToTheLanesOtherColumn() throws {
        let roots = [
            node(try target(1, "Plan A"), [
                node(try target(2)),
                node(Target(row: Row(["id": 3, "text": "Future", "status": "someday", "priority": "medium"])))
            ]),
            node(try target(4, "Plan B"), [node(try target(5))])
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(board.lanes.map { $0.columns.last?.status }, [WorkbenchBoardKanban.otherStatus, WorkbenchBoardKanban.otherStatus])
        XCTAssertEqual(laneIDs(lane(board, 1), WorkbenchBoardKanban.otherStatus), [3])
        XCTAssertEqual(laneIDs(lane(board, 4), WorkbenchBoardKanban.otherStatus), [])
        XCTAssertEqual(laneIDs(lane(board, 1), "todo"), [2], "the Other card is in no known column")
        XCTAssertEqual(lane(board, 1)?.columns.last?.acceptsDrops, false)
        XCTAssertEqual(board.totals[WorkbenchBoardKanban.otherStatus], 1)

        let known = WorkbenchBoardKanban([roots[1]], scopeID: nil, showDone: false)
        XCTAssertFalse(known.lanes.contains { $0.columns.contains { $0.status == WorkbenchBoardKanban.otherStatus } })
    }

    /// A live dismissed card waits for Show done in a lane too; with it on
    /// the lane's Dismissed column holds it, and it never counts in the
    /// lane's progress.
    func testALiveDismissedCardShowsInItsLaneOnlyWithShowDone() throws {
        let roots = [
            node(try target(1, "Plan", status: "in_progress"), [
                node(try target(2)),
                node(try target(3, status: "dismissed"))
            ])
        ]
        let off = try XCTUnwrap(lane(WorkbenchBoardKanban(roots, scopeID: nil, showDone: false), 1))
        XCTAssertFalse(off.columns.contains { $0.status == "dismissed" })
        XCTAssertFalse(off.showsCard(3))

        let on = try XCTUnwrap(lane(WorkbenchBoardKanban(roots, scopeID: nil, showDone: true), 1))
        let dismissed = try XCTUnwrap(on.columns.first { $0.status == "dismissed" })
        XCTAssertEqual(on.cards(dismissed, unfolded: false).map(\.id), [3], "the Done fold never touches Dismissed")
        XCTAssertTrue(on.showsCard(3))
        XCTAssertEqual(on.progress, WorkbenchBoardKanban.Lane.Progress(done: 0, total: 1))
    }

    func testLaneShowsOnlyItsOwnCards() throws {
        let roots = [
            node(try target(1, "Plan A"), [node(try target(2)), node(try target(6, status: "done"))]),
            node(try target(3, "Plan B"), [node(try target(4))]),
            node(try target(5, "Lone leaf"))
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        let a = try XCTUnwrap(lane(board, 1)), b = try XCTUnwrap(lane(board, 3)), none = try XCTUnwrap(lane(board, 0))
        XCTAssertTrue(a.showsCard(2))
        XCTAssertTrue(a.showsCard(6), "a folded done card is still the lane's")
        XCTAssertFalse(a.showsCard(4))
        XCTAssertFalse(a.showsCard(5))
        XCTAssertFalse(a.showsCard(1), "the lane root is never a card")
        XCTAssertTrue(b.showsCard(4))
        XCTAssertFalse(b.showsCard(2))
        XCTAssertTrue(none.showsCard(5))
        XCTAssertFalse(none.showsCard(2))
    }

    func testTotalsPerStatusAreTheSumOverTheLanes() throws {
        let roots = [
            node(try target(1, "Plan A", status: "in_progress"), [
                node(try target(2)), node(try target(3, status: "in_progress")), node(try target(4, status: "done"))
            ]),
            node(try target(5, "Plan B"), [node(try target(6)), node(try target(7, status: "blocked"))]),
            node(try target(8, "Lone leaf", status: "done")),
            node(try target(9, "Lone leaf"))
        ]
        for showDone in [false, true] {
            let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: showDone)
            XCTAssertEqual(Set(board.totals.keys), Set(board.columns.map(\.status)))
            for column in board.columns {
                let sum = board.lanes.reduce(0) { $0 + ($1.columns.first { $0.status == column.status }?.cards.count ?? 0) }
                XCTAssertEqual(board.totals[column.status], sum, "\(column.status), showDone \(showDone)")
            }
            XCTAssertEqual(board.totals["todo"], 3)
            XCTAssertEqual(board.totals["done"], 2)
        }
    }

    func testAnEmptyClosedLaneIsHiddenAndArchiveBringsItsArchivedCardsBack() throws {
        let roots = [
            node(try target(1, "Live"), [node(try target(2))]),
            node(try target(3, "Closed", status: "done"), [
                node(try target(4, status: "done")), node(try target(5, status: "dismissed"))
            ]),
            node(try target(6, "Gone", status: "done"), [
                node(try target(7, status: "done"), archived: true),
                node(try target(8, status: "dismissed"), archived: true)
            ], archived: true)
        ]
        let off = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(off.lanes.map(\.id), [1], "an all-closed lane with Show done off has nothing to show")
        XCTAssertEqual(off.totals["done"], 0, "a hidden lane adds nothing to the totals")

        let archive = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, showArchived: true)
        XCTAssertEqual(archive.lanes.map(\.id), [1, 6])
        let gone = try XCTUnwrap(lane(archive, 6))
        let goneDone = try XCTUnwrap(gone.columns.first { $0.status == "done" })
        XCTAssertEqual(gone.cards(goneDone, unfolded: false).map(\.id), [7])
        XCTAssertEqual(laneIDs(gone, "dismissed"), [8])

        let showDone = WorkbenchBoardKanban(roots, scopeID: nil, showDone: true)
        XCTAssertEqual(showDone.lanes.map(\.id), [1, 3])
    }

    /// An open root keeps its lane while the search is empty — the view says
    /// "No open tasks"; a search hides every lane it leaves empty.
    func testAnOpenRootKeepsItsEmptyLaneOnlyWithoutASearch() throws {
        let roots = [
            node(try target(1, "Waiting", status: "in_progress"), [
                node(try target(2, status: "done")), node(try target(3, status: "dismissed"))
            ]),
            node(try target(4, "Widget"), [node(try target(5, "Widget part"))]),
            node(try target(6, "Lone leaf", status: "done"))
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [1, 4], "No group has no root to keep it")
        let waiting = try XCTUnwrap(lane(board, 1))
        XCTAssertTrue(waiting.columns.allSatisfy { waiting.cards($0, unfolded: false).isEmpty })
        XCTAssertEqual(waiting.doneCount, 1)

        let emptyRoot = [node(try target(7, "Bare", status: "todo"), [node(try target(8, status: "dismissed"))])]
        let bare = try XCTUnwrap(WorkbenchBoardKanban(emptyRoot, scopeID: nil, showDone: false).lanes.first)
        XCTAssertEqual(bare.id, 7)
        XCTAssertTrue(bare.columns.allSatisfy(\.cards.isEmpty), "kept with no cards at all")

        let searched = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, query: "widget")
        XCTAssertEqual(searched.lanes.map(\.id), [4])
    }

    /// One counting rule (R13): a lane's progress is its group's
    /// `WorkbenchGroupSummary` — the panel's and the path bar's — so an
    /// archived leaf counts only with the Archive toggle on, a search never
    /// turns it on, a dismissed leaf never counts and a nested group counts
    /// through its own leaves.
    func testLaneProgressCountsDoneLeavesOverLeavesThatCount() throws {
        let roots = [
            node(try target(1, "Plan"), [
                node(try target(2, status: "done")),
                node(try target(3, status: "dismissed")),
                node(try target(4, "Nested"), [node(try target(5, status: "done")), node(try target(6))]),
                node(try target(9, status: "done"), archived: true)
            ]),
            node(try target(7, "Lone leaf")),
            node(try target(8, "Lone leaf", status: "done"))
        ]
        typealias Progress = WorkbenchBoardKanban.Lane.Progress
        for (archive, expected) in [(false, Progress(done: 2, total: 3)), (true, Progress(done: 3, total: 4))] {
            for query in ["", "#6"] {
                let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, showArchived: archive, query: query)
                let plan = try XCTUnwrap(lane(board, 1))
                let summary = WorkbenchGroupSummary(try XCTUnwrap(plan.root), showArchived: archive)
                XCTAssertEqual(plan.progress, expected, "Archive \(archive), query '\(query)'")
                XCTAssertEqual(plan.progress, Progress(done: summary.done, total: summary.total),
                               "the lane and the panel agree")
                if query.isEmpty {
                    XCTAssertEqual(lane(board, 0)?.progress, Progress(done: 1, total: 2))
                }
            }
            // Entered: the path bar's summary of the scope is the same number
            // the lane showed for it on the board.
            let scoped = WorkbenchBoardKanban(roots, scopeID: 1, showDone: false, showArchived: archive)
            let scope = try XCTUnwrap(scoped.scopePath.last)
            let pathBar = WorkbenchGroupSummary(scope, showArchived: archive)
            XCTAssertEqual(Progress(done: pathBar.done, total: pathBar.total), expected, "Archive \(archive)")
        }
    }

    func testLanesFollowTheParentFilter() throws {
        let roots = [
            node(try target(1, "Plan A"), [node(try target(2))]),
            node(try target(3, "Plan B"), [node(try target(4))]),
            node(try target(5, "Lone leaf"))
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: 3, showDone: false)
        XCTAssertEqual(board.lanes.map(\.id), [3])
    }

    func testEmptyBoardHasNoLanesAndZeroTotals() {
        let board = WorkbenchBoardKanban([], scopeID: nil, showDone: false)
        XCTAssertTrue(board.lanes.isEmpty)
        XCTAssertEqual(board.totals, ["todo": 0, "in_progress": 0, "in_review": 0, "blocked": 0, "done": 0])
    }

    // MARK: - Preferences

    func testPreferencesArePerProjectAndDefaultToListAndAll() throws {
        let suite = "WorkbenchBoardKanbanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let one = WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults)
        XCTAssertEqual(one.mode, .list)
        XCTAssertNil(one.boardScopeID)

        one.mode = .kanban
        one.boardScopeID = 42
        XCTAssertEqual(defaults.string(forKey: "projects.boardMode.1"), "kanban")
        XCTAssertEqual(defaults.integer(forKey: "projects.boardKanbanFilter.1"), 42)

        let reread = WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults)
        XCTAssertEqual(reread.mode, .kanban)
        XCTAssertEqual(reread.boardScopeID, 42)

        let two = WorkbenchBoardPreferences(workbenchID: 2, defaults: defaults)
        XCTAssertEqual(two.mode, .list)
        XCTAssertNil(two.boardScopeID)

        one.boardScopeID = nil
        XCTAssertNil(defaults.object(forKey: "projects.boardKanbanFilter.1"))
        defaults.set("bogus", forKey: "projects.boardMode.1")
        XCTAssertEqual(WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults).mode, .list)
    }

    func testLanesPreferencesRoundTripPerProject() throws {
        let suite = "WorkbenchBoardKanbanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let one = WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults)
        XCTAssertEqual(one.lanesMode, .group)
        XCTAssertEqual(one.foldedLanes, [])

        one.lanesMode = .none
        one.foldedLanes = [42, 0, 7]
        XCTAssertEqual(defaults.string(forKey: "projects.boardLanes.1"), "none")
        XCTAssertEqual(defaults.array(forKey: "projects.boardFoldedLanes.1") as? [Int], [0, 7, 42])

        let reread = WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults)
        XCTAssertEqual(reread.lanesMode, .none)
        XCTAssertEqual(reread.foldedLanes, [0, 7, 42], "a folded id is kept whether or not it is still a lane")

        let two = WorkbenchBoardPreferences(workbenchID: 2, defaults: defaults)
        XCTAssertEqual(two.lanesMode, .group)
        XCTAssertEqual(two.foldedLanes, [])

        defaults.set("bogus", forKey: "projects.boardLanes.1")
        XCTAssertEqual(WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults).lanesMode, .group)
        one.foldedLanes = []
        XCTAssertEqual(WorkbenchBoardPreferences(workbenchID: 1, defaults: defaults).foldedLanes, [])
    }
}
