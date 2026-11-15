import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The board tree, its quick filters and search (#1781) over the demo
/// board: Waiting for me, Sessions running, High, Blocked, All, Done and
/// Archive; lanes in the owner's column order.
final class BoardFilterTests: XCTestCase {
    private let now = Date()

    private func board(_ filter: BoardFilter? = nil, query: String = "") throws -> BoardModel {
        BoardModel(workbenchID: DemoSeed.acmeID, snapshot: try demoSnapshot(now: now), filter: filter, query: query)
    }

    private func archivedIDs() throws -> Set<Int64> {
        Set(try demoSnapshot(now: now).targets.filter(\.archived).map(\.id))
    }

    private func node(_ id: Int64, in nodes: [BoardNode]) -> BoardNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = self.node(id, in: node.children) { return found }
        }
        return nil
    }

    func testTheFiltersInOrder() {
        XCTAssertEqual(
            BoardFilter.allCases.map(\.title),
            ["Waiting for me", "Sessions running", "High", "Blocked", "All", "Done", "Archive"]
        )
    }

    func testTheChipCounts() throws {
        let board = try board()
        XCTAssertEqual(board.count(.waiting), 3, "415 and 431 have asks, 421's session needs approval")
        XCTAssertEqual(board.count(.sessions), 1)
        XCTAssertEqual(board.count(.high), 3)
        XCTAssertEqual(board.count(.blocked), 1)
        XCTAssertEqual(board.count(.all), 10)
        XCTAssertEqual(board.count(.done), 1)
        XCTAssertNil(board.count(.archive), "the Archive chip carries no count")
    }

    /// The opening filter: Waiting for me, else Sessions running, else All.
    func testTheBoardOpensOnWhatWaitsThenWhatRunsThenAll() throws {
        XCTAssertEqual(try board().filter, .waiting)
        XCTAssertEqual(BoardFilter.opening(counts: [.waiting: 0, .sessions: 2, .all: 5]), .sessions)
        XCTAssertEqual(BoardFilter.opening(counts: [.waiting: 0, .sessions: 0, .all: 5]), .all)
        XCTAssertEqual(BoardFilter.opening(counts: [:]), .all)
        XCTAssertEqual(try board(.blocked).filter, .blocked, "the owner's chip wins")
    }

    func testWaitingForMeKeepsAncestorsAndLanesInColumnOrder() throws {
        let waiting = try board(.waiting)
        XCTAssertEqual(waiting.lanes.map(\.title), ["Todo", "In progress"])
        XCTAssertEqual(waiting.lanes.first?.nodes.map(\.id), [420, 431])
        XCTAssertEqual(node(420, in: waiting.roots)?.children.map(\.id), [421], "the approval waits on 421")
        XCTAssertEqual(node(400, in: waiting.roots)?.children.map(\.id), [415])
        XCTAssertFalse(waiting.folds, "a narrow filter shows every match open")
    }

    func testSessionsRunningShowsTheWorkingTarget() throws {
        XCTAssertEqual(try board(.sessions).visibleIDs, [430])
    }

    func testHighAndBlocked() throws {
        XCTAssertEqual(try board(.high).visibleIDs, [400, 415, 420, 421, 434])
        let blocked = try board(.blocked)
        XCTAssertEqual(blocked.roots.map(\.id), [420])
        XCTAssertEqual(blocked.roots.first?.children.map(\.id), [421])
    }

    func testDoneShowsDoneTargetsUnderTheirGroup() throws {
        let done = try board(.done)
        XCTAssertEqual(done.visibleIDs, [420, 422])
        XCTAssertTrue(try XCTUnwrap(node(422, in: done.roots)).isDimmed)
    }

    func testArchiveShowsOnlyArchivedRecords() throws {
        let archive = try board(.archive)
        XCTAssertEqual(archive.visibleIDs, try archivedIDs())
        XCTAssertEqual(Set(archive.roots.map(\.id)), [390, 391, 417], "an archived child of a live group is a root here")
        XCTAssertEqual(archive.lanes.map(\.title), ["Dismissed", "Done"])
    }

    func testTheOtherFiltersNeverShowArchivedRecords() throws {
        let archived = try archivedIDs()
        for filter in BoardFilter.allCases where filter != .archive {
            let visible = try board(filter).visibleIDs
            XCTAssertTrue(visible.isDisjoint(with: archived), "\(filter.title) shows an archived target")
            XCTAssertFalse(visible.isEmpty, "\(filter.title) is empty on the demo board")
        }
    }

    /// All: the owner's lanes (Backlog, Todo from `board_columns`, then the
    /// status lanes in Kanban order) and folds.
    func testAllLaysTheLanesOutInTheOwnersColumnOrder() throws {
        let all = try board(.all)
        XCTAssertTrue(all.folds)
        XCTAssertEqual(all.lanes.map(\.title), ["Backlog", "Todo", "In progress"])
        XCTAssertEqual(all.lanes.map { $0.nodes.map(\.id) }, [[432, 433], [434, 420, 431], [400, 430]])
        XCTAssertEqual(node(420, in: all.roots)?.children.map(\.id), [421], "a done sub-target is under Done")
    }

    /// An old Mac sends no `board_columns`: lanes go in status order, then
    /// first seen (the board order).
    func testAnOldMacWithoutColumnsOrdersLanesByStatus() throws {
        var snapshot = try demoSnapshot(now: now)
        var json = DemoSeed.JSON.workbench(DemoSeed.acmeID)
        json["board_columns"] = nil
        snapshot.workbenches = [try mirror(Workbench.self, json)]
        XCTAssertNil(snapshot.workbench(DemoSeed.acmeID)?.boardColumns)
        let all = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, filter: .all)
        XCTAssertEqual(all.lanes.map(\.title), ["Todo", "Backlog", "In progress"])
    }

    func testLaneOrderWithColumnsAcrossStatuses() throws {
        func root(_ id: Int64, _ status: WorkbenchTargetStatus, _ label: String) -> BoardNode {
            BoardNode(
                id: id, status: status, label: label,
                card: BoardCardModel(number: id, title: "x", status: status, statusText: label, priority: .medium),
                isDimmed: status == .done, children: []
            )
        }
        let roots = [
            root(1, .inProgress, "Coding"), root(2, .blocked, "Blocked"), root(3, .todo, "Todo"),
            root(4, .done, "Done"), root(5, .inProgress, "In progress"), root(6, .todo, "Backlog"), root(7, .inReview, "Review")
        ]
        let lanes = BoardLane.lanes(roots, columns: ["Backlog", "Todo", "Coding", "Review"])
        XCTAssertEqual(lanes.map(\.title), ["Backlog", "Todo", "Coding", "In progress", "Review", "Blocked", "Done"])
        XCTAssertEqual(lanes.last?.kind, .done)
        XCTAssertEqual(BoardLane.lanes(roots, columns: nil).map(\.title), ["Todo", "Backlog", "Coding", "In progress", "Review", "Blocked", "Done"])
    }

    /// A decoded `board_columns` with a duplicate or a title no lane has
    /// (renamed on the Mac since) still gives every lane once, in a stable
    /// order: the first place of a title wins, an unknown title is skipped,
    /// and a lane missing from the list goes after its status's columns.
    func testDuplicateAndUnknownColumnTitlesKeepASaneOrder() throws {
        func lanes(_ columns: [String]) throws -> [String] {
            var snapshot = try demoSnapshot(now: now)
            var json = DemoSeed.JSON.workbench(DemoSeed.acmeID)
            json["board_columns"] = columns
            snapshot.workbenches = [try mirror(Workbench.self, json)]
            XCTAssertEqual(snapshot.workbench(DemoSeed.acmeID)?.boardColumns, columns)
            return BoardModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, filter: .all).lanes.map(\.title)
        }
        XCTAssertEqual(try lanes(["Todo", "Backlog", "Todo"]), ["Todo", "Backlog", "In progress"])
        XCTAssertEqual(try lanes(["Gone", "Backlog", "Coding"]), ["Backlog", "Todo", "In progress"])
        XCTAssertEqual(try lanes([]), ["Todo", "Backlog", "In progress"], "an empty list reads like none")
    }

    /// An ask or a permission prompt shared by two sub-targets (one session
    /// on both) counts once on their group (codex review of #873).
    func testAGroupCountsASharedAskAndPromptOnce() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.targets = snapshot.targets.map { target in
            guard target.id == 416 else { return target }
            var json = DemoSeed.JSON.target(416, workbench: DemoSeed.acmeID, ["parent_id": 400, "text": "Undo Archive Now"])
            json["session_ids"] = [11, 12]
            return (try? mirror(WorkbenchTarget.self, json)) ?? target
        }
        snapshot.targets = snapshot.targets.map { target in
            guard target.id == 415 else { return target }
            var json = DemoSeed.JSON.target(415, workbench: DemoSeed.acmeID, ["parent_id": 400, "text": "Archive Closed Targets Now"])
            json["session_ids"] = [11, 12]
            json["open_asks"] = 2
            return (try? mirror(WorkbenchTarget.self, json)) ?? target
        }
        let all = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, filter: .all)
        let group = try XCTUnwrap(node(400, in: all.roots)).card
        // Asks 109 and 111 (session 11, filed on 415) and session 12's
        // approval reach both children: two asks and one approval, not four
        // and two.
        XCTAssertEqual(group.details.filter { $0.role == .ask }.map(\.text), ["2 asks", "1 approval"])
    }

    /// #1191: a target's sub-targets hide done ones the same way; the
    /// header still counts them all.
    func testTheDetailHidesDoneSubTargetsUntilShowDone() throws {
        let snapshot = try demoSnapshot(now: now)
        let hidden = try XCTUnwrap(BoardTargetDetailModel(targetID: 420, snapshot: snapshot, now: now))
        XCTAssertEqual(hidden.children.map(\.id), [421])
        XCTAssertEqual(hidden.doneChildCount, 1)
        XCTAssertEqual(hidden.childrenHeader, "Sub-targets · 1/2")
        XCTAssertEqual(hidden.childCounter, "1/2")
        let shown = try XCTUnwrap(BoardTargetDetailModel(targetID: 420, snapshot: snapshot, now: now, showDone: true))
        XCTAssertEqual(shown.children.map(\.id), [421, 422])
        XCTAssertEqual(shown.childrenHeader, hidden.childrenHeader)
        let leaf = try XCTUnwrap(BoardTargetDetailModel(targetID: 421, snapshot: snapshot, now: now))
        XCTAssertEqual(leaf.childrenHeader, "Sub-targets")
        XCTAssertNil(leaf.childCounter)
        XCTAssertEqual(leaf.doneChildCount, 0)
    }

    /// #1788: a group with an archived child says one number in the header
    /// and the list, and names the archived one instead of counting it.
    func testAGroupCountsItsArchivedChildApart() throws {
        let group = try XCTUnwrap(BoardTargetDetailModel(targetID: 400, snapshot: try demoSnapshot(now: now), now: now))
        XCTAssertEqual(group.children.map(\.id).sorted(), [415, 416])
        XCTAssertEqual(group.childCounter, "0/2 · 1 archived")
        XCTAssertEqual(group.childrenHeader, "Sub-targets · 0/2 · 1 archived")
    }

    func testTheChildCounterWords() {
        XCTAssertEqual(BoardTargetDetailModel.childCounter(done: 1, listed: 3, archived: 0), "1/3")
        XCTAssertEqual(BoardTargetDetailModel.childCounter(done: 0, listed: 0, archived: 2), "0/0 · 2 archived")
        XCTAssertEqual(BoardTargetDetailModel.childCounter(done: 1, listed: 2, archived: -1), "1/2", "a replica ahead of the count")
        XCTAssertNil(BoardTargetDetailModel.childCounter(done: 0, listed: 0, archived: 0))
    }

    /// An archived group lists its archived children and names none apart.
    func testAnArchivedGroupHasNoArchivedNote() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.targets.append(try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(900, workbench: DemoSeed.acmeID, [
            "text": "Old group", "archived": true, "status": "done", "children_count": 2
        ])))
        snapshot.targets.append(try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(901, workbench: DemoSeed.acmeID, [
            "parent_id": 900, "text": "Old child", "archived": true, "status": "done"
        ])))
        let group = try XCTUnwrap(BoardTargetDetailModel(targetID: 900, snapshot: snapshot, now: now))
        XCTAssertEqual(group.childCounter, "1/1")
    }

    func testBacklogAndDoneStartFolded() throws {
        let all = try board(.all)
        let folds = BoardFolds()
        XCTAssertEqual(all.lanes.map { folds.isLaneOpen($0) }, [false, true, true])
        XCTAssertTrue(BoardLane(title: "Done", nodes: [], kind: .done).isFoldedByDefault)
        XCTAssertTrue(BoardLane(title: "backlog", nodes: [], kind: .open).isFoldedByDefault)
    }

    // MARK: - Search

    func testSearchByTitleNumberAndBranch() throws {
        XCTAssertEqual(try board(query: "lane").visibleIDs, [420, 421, 422, 433], "title, any status")
        XCTAssertEqual(try board(query: "#421").visibleIDs, [420, 421])
        XCTAssertEqual(try board(query: "  #43 ").visibleIDs, [430, 431, 432, 433, 434], "an id prefix, trimmed")
        XCTAssertEqual(try board(query: "board-search").visibleIDs, [434], "branch")
        XCTAssertEqual(try board(query: "ÉXPORT").visibleIDs, [432], "case and diacritics ignored")
        XCTAssertEqual(try board(query: "#lane").visibleIDs, [], "# searches numbers only")
    }

    /// A search covers the whole board: the chip does not narrow it, and an
    /// archived match lands in the Archived lane at the end, dimmed.
    func testSearchCoversTheWholeBoardWithArchivedLast() throws {
        let search = try board(.blocked, query: "archive")
        XCTAssertTrue(search.isSearching)
        XCTAssertFalse(search.folds)
        XCTAssertEqual(search.lanes.map(\.title), ["In progress", "Archived"])
        XCTAssertEqual(search.lanes.last?.nodes.map(\.id), [417])
        XCTAssertEqual(search.lanes.last?.nodes.first?.isDimmed, true)
        XCTAssertEqual(search.matchCount, 4)
        XCTAssertEqual(search.searchCaption, "4 matches")
        XCTAssertNil(search.emptyText)
    }

    func testEmptyTexts() throws {
        let none = try board(query: "zzz")
        XCTAssertEqual(none.emptyText, "No target matches \u{201C}zzz\u{201D}")
        XCTAssertNil(none.searchCaption, "the empty line alone says it")
        XCTAssertEqual(try board(query: "#434").searchCaption, "1 match")
        let notes = BoardModel(workbenchID: DemoSeed.notesID, snapshot: try demoSnapshot(now: now))
        XCTAssertEqual(notes.filter, .all)
        XCTAssertEqual(notes.emptyText, "No open targets")
        XCTAssertEqual(
            BoardFilter.allCases.map(\.emptyText),
            ["Nothing waits for you", "No session is running", "No high-priority targets", "Nothing blocked",
             "No open targets", "Nothing done", "Nothing archived"]
        )
        XCTAssertNil(try board().emptyText)
    }

    // MARK: - Rows

    /// Twin of Core's `WorkbenchBoardOrder` and Go's `boardSiblingOrder`.
    func testSiblingOrderIsPriorityThenStatusThenID() throws {
        func target(_ id: Int64, _ priority: String, _ status: String) throws -> WorkbenchTarget {
            try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(id, workbench: 1, ["priority": priority, "status": status]))
        }
        let targets = [
            try target(1, "low", "in_progress"),
            try target(2, "medium", "todo"),
            try target(3, "high", "todo"),
            try target(4, "medium", "in_progress"),
            try target(5, "medium", "blocked"),
            try target(6, "medium", "in_review"),
            try target(7, "high", "todo"),
            try target(8, "medium", "done")
        ]
        XCTAssertEqual(targets.sorted(by: BoardModel.boardOrder).map(\.id), [3, 7, 4, 6, 5, 2, 8, 1])
    }

    func testATargetWithZeroChildrenHasNoDisclosure() throws {
        let all = try board(.all)
        XCTAssertTrue(try XCTUnwrap(node(400, in: all.roots)).hasDisclosure)
        XCTAssertFalse(try XCTUnwrap(node(416, in: all.roots)).hasDisclosure)
        XCTAssertFalse(try XCTUnwrap(node(431, in: all.roots)).hasDisclosure)
    }

    /// The compact row: no status chip in its own lane, High as a dot only,
    /// meta on the number's line, no bar on a leaf.
    func testACompactLeaf() throws {
        let waiting = try board(.waiting)
        let card = try XCTUnwrap(node(415, in: waiting.roots)).card
        XCTAssertTrue(card.isCompact)
        XCTAssertEqual(card.chips, [], "In progress inside In progress, and no priority chip")
        XCTAssertEqual(card.priorityDot, .red)
        XCTAssertNil(card.progress, "a leaf draws no bar")
        XCTAssertNil(card.counter)
        XCTAssertEqual(card.details.map(\.text), ["2 asks", "1 session", "PR #175"])
        XCTAssertEqual(card.details.first?.tone, .waitingForYou)

        let blocked = try XCTUnwrap(node(421, in: waiting.roots)).card
        XCTAssertEqual(blocked.chips.map(\.text), ["Blocked"], "a child in another status says so in the Todo lane")
        XCTAssertEqual(blocked.details.map(\.text), ["1 approval", "2 sessions"])

        let low = try XCTUnwrap(node(431, in: waiting.roots)).card
        XCTAssertNil(low.priorityDot, "only High is drawn")
        XCTAssertEqual(low.chips, [])
        let working = try XCTUnwrap(node(430, in: try board(.sessions).roots)).card
        XCTAssertEqual(working.sessionsText, "1 session")
        XCTAssertEqual(working.details, [], "the live dot says it")
    }

    /// A group sums its subtree: counter, asks and approvals, a bar.
    func testACompactGroupSummarisesItsSubtree() throws {
        let all = try board(.all)
        let hierarchy = try XCTUnwrap(node(420, in: all.roots)).card
        XCTAssertEqual(hierarchy.counter, "1/2")
        XCTAssertEqual(hierarchy.details.map(\.text), ["1 approval"])
        XCTAssertEqual(try XCTUnwrap(hierarchy.progress), 0.5, accuracy: 0.0001)
        let archive = try XCTUnwrap(node(400, in: all.roots)).card
        XCTAssertEqual(archive.details.map(\.text), ["2 asks"])
        XCTAssertEqual(archive.counter, "0/2 · 1 archived", "the detail's rule (#1788)")
        XCTAssertEqual(archive.chips, [])
    }

    func testTheTargetDetailIsReadOnlyAndComplete() throws {
        let snapshot = try demoSnapshot(now: now)
        let detail = try XCTUnwrap(BoardTargetDetailModel(targetID: 415, snapshot: snapshot, now: now))
        XCTAssertEqual(detail.title, "Archive Closed Targets Now")
        XCTAssertEqual(detail.statusLabel, "In progress")
        XCTAssertEqual(detail.intent, "Archive closed targets on demand from the header menu.")
        XCTAssertEqual(detail.sessions.map(\.id), [11])
        XCTAssertEqual(detail.asks.map(\.id), [.ask(111), .ask(109)])
        XCTAssertEqual(detail.comments.map(\.id), [80, 81])
        XCTAssertEqual(detail.comments.map(\.isReply), [false, true])
        XCTAssertNil(BoardTargetDetailModel(targetID: 999, snapshot: snapshot, now: now))

        let group = try XCTUnwrap(BoardTargetDetailModel(targetID: 400, snapshot: snapshot, now: now))
        XCTAssertEqual(group.children.map(\.id), [415, 416], "archived children stay out of the detail")
    }

    func testShowDoneButtonTitle() {
        XCTAssertEqual(ShowDoneButton.title(doneCount: 3, showDone: false), "Show done (3)")
        XCTAssertEqual(ShowDoneButton.title(doneCount: 3, showDone: true), "Hide done")
    }
}
