import XCTest
import GRDB
@testable import WatchtowerCore

/// Workbench board columns on the Desktop Kanban (board #267, spec
/// 2026-10-16 §3/§6): the slot layout built from a definition and the
/// Kanban re-keyed by slot. Pure; targets come from rows, not a database.
final class BoardColumnLayoutTests: XCTestCase {
    private func col(
        _ id: Int64, _ status: String, _ title: String, position: Int, description: String = ""
    ) -> WorkbenchBoardColumnDef {
        WorkbenchBoardColumnDef(id: id, status: status, title: title, description: description, position: position)
    }

    /// in_progress "Spec" (10) and "Code" (11), done "Shipped" (12) and
    /// "Released" (13); listed out of order on purpose.
    private var def: WorkbenchBoardColumns {
        WorkbenchBoardColumns(columns: [
            col(12, "done", "Shipped", position: 0),
            col(11, "in_progress", "Code", position: 1, description: "Writing the code"),
            col(13, "done", "Released", position: 1),
            col(10, "in_progress", "Spec", position: 0)
        ], hidden: [])
    }

    private func slotKeys(_ slots: [BoardColumnSlot]) -> [String] { slots.map(\.key) }

    // MARK: - Layout

    func testEmptyDefinitionIsTodaysColumns() {
        let slots = BoardColumnLayout.slots(.empty, occupiedStatuses: [], showDismissed: false)
        XCTAssertEqual(slotKeys(slots), ["todo", "in_progress", "in_review", "blocked", "done"])
        XCTAssertEqual(slots.map(\.title), ["To Do", "In Progress", "In Review", "Blocked", "Done"])
        XCTAssertEqual(slots.map(\.status), slotKeys(slots), "an implicit column's key is its status")
        XCTAssertTrue(slots.allSatisfy { $0.columnID == nil && $0.categoryLabel == nil && $0.description.isEmpty })

        let withDismissed = BoardColumnLayout.slots(.empty, occupiedStatuses: [], showDismissed: true)
        XCTAssertEqual(slotKeys(withDismissed).last, "dismissed")
        XCTAssertTrue(WorkbenchBoardColumns.empty.isEmpty)
    }

    func testDefinedColumnsInStatusOrderThenPosition() {
        let slots = BoardColumnLayout.slots(def, occupiedStatuses: [], showDismissed: false)
        XCTAssertEqual(slotKeys(slots), ["todo", "c10", "c11", "in_review", "blocked", "c12", "c13"])
        XCTAssertEqual(slots.map(\.title), ["To Do", "Spec", "Code", "In Review", "Blocked", "Shipped", "Released"])
        XCTAssertEqual(slots[2].columnID, 11)
        XCTAssertEqual(slots[2].status, "in_progress")
        XCTAssertEqual(slots[2].description, "Writing the code")
        XCTAssertFalse(def.isEmpty)
    }

    func testHiddenEmptyStatusIsSkipped() {
        let hidden = WorkbenchBoardColumns(columns: [], hidden: ["in_review", "blocked"])
        let slots = BoardColumnLayout.slots(hidden, occupiedStatuses: ["todo", "done"], showDismissed: false)
        XCTAssertEqual(slotKeys(slots), ["todo", "in_progress", "done"])
        XCTAssertFalse(hidden.isEmpty, "something hidden is a definition")
    }

    /// Review focus 3: a hidden status that still holds cards keeps one
    /// column under its standard label, even with columns defined for it.
    func testHiddenStatusWithCardsStillShows() {
        let hidden = WorkbenchBoardColumns(columns: [col(20, "blocked", "Waiting", position: 0)], hidden: ["blocked"])
        let slots = BoardColumnLayout.slots(hidden, occupiedStatuses: ["blocked"], showDismissed: false)
        XCTAssertEqual(slotKeys(slots), ["todo", "in_progress", "in_review", "blocked", "done"])
        let blocked = slots[3]
        XCTAssertEqual(blocked.title, "Blocked")
        XCTAssertNil(blocked.columnID)
        XCTAssertNil(blocked.categoryLabel)
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "blocked", columnID: 20, def: hidden), "blocked")
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "blocked", columnID: nil, def: hidden), "blocked")
    }

    /// Review focus 2: a NULL or foreign column is the status's first column.
    func testCardWithNullColumnGoesToFirstColumn() throws {
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "in_progress", columnID: nil, def: def), "c10")
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "in_progress", columnID: 11, def: def), "c11")
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "in_progress", columnID: 12, def: def), "c10", "a done column")
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "in_progress", columnID: 99, def: def), "c10", "a deleted column")
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "todo", columnID: nil, def: def), "todo")
        XCTAssertEqual(BoardColumnLayout.slotKey(status: "in_progress", columnID: nil, def: .empty), "in_progress")

        let board = WorkbenchBoardKanban(
            [node(1, status: "in_progress"), node(2, status: "in_progress", column: 11)],
            scopeID: nil, showDone: false, columns: def
        )
        XCTAssertEqual(board.columns.first { $0.key == "c10" }?.cards.map(\.id), [1])
        XCTAssertEqual(board.columns.first { $0.key == "c11" }?.cards.map(\.id), [2])
    }

    func testCategoryLabelOnlyWhenTitleDiffers() {
        let same = WorkbenchBoardColumns(columns: [
            col(30, "in_progress", "In Progress", position: 0),
            col(31, "in_progress", "Code", position: 1)
        ], hidden: [])
        let slots = BoardColumnLayout.slots(same, occupiedStatuses: [], showDismissed: false)
        XCTAssertNil(slots.first { $0.key == "c30" }?.categoryLabel)
        XCTAssertEqual(slots.first { $0.key == "c31" }?.categoryLabel, "In Progress")
        XCTAssertNil(slots.first { $0.key == "todo" }?.categoryLabel)
    }

    // MARK: - Kanban

    private func node(
        _ id: Int, status: String, column: Int64? = nil, children: [WorkbenchBoardNode] = []
    ) -> WorkbenchBoardNode {
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": id, "text": "Task \(id)", "status": status, "priority": "medium",
            "updated_at": "2026-10-16T10:00:0\(id % 10)Z"
        ]
        values["board_column_id"] = column
        return WorkbenchBoardNode(
            target: Target(row: Row(values)), children: children, openComments: 0, unreadForOwner: 0
        )
    }

    /// The old `Dictionary(uniqueKeysWithValues:)` keyed by status would trap
    /// on two in_progress columns; totals are per column key now.
    func testKanbanWithTwoInProgressColumnsHasDistinctTotals() {
        let roots = [
            node(100, status: "in_progress", children: [
                node(1, status: "in_progress", column: 10),
                node(2, status: "in_progress", column: 11),
                node(3, status: "in_progress", column: 11)
            ]),
            node(4, status: "todo")
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, columns: def)

        XCTAssertEqual(board.columns.map(\.id), ["todo", "c10", "c11", "in_review", "blocked", "c12", "c13"])
        XCTAssertEqual(board.totals, ["todo": 1, "c10": 1, "c11": 2, "in_review": 0, "blocked": 0, "c12": 0, "c13": 0])
        let code = board.columns[2]
        XCTAssertEqual(code.columnID, 11)
        XCTAssertEqual(code.status, "in_progress")
        XCTAssertEqual(code.title, "Code")
        XCTAssertEqual(code.description, "Writing the code")
        XCTAssertEqual(code.categoryLabel, "In Progress")
        XCTAssertTrue(code.acceptsDrops)
        for lane in board.lanes {
            XCTAssertEqual(lane.columns.map(\.key), board.columns.map(\.key), "lanes line up under the totals row")
        }
        XCTAssertEqual(board.lanes.first?.columns.first { $0.key == "c11" }?.cards.map(\.id), [2, 3])
    }

    func testDoneFoldCoversEveryDoneColumn() throws {
        let roots = [
            node(100, status: "in_progress", children: [
                node(1, status: "done", column: 12),
                node(2, status: "done", column: 13),
                node(3, status: "done"),
                node(4, status: "todo")
            ])
        ]
        let board = WorkbenchBoardKanban(roots, scopeID: nil, showDone: false, columns: def)
        let lane = try XCTUnwrap(board.lanes.first)

        XCTAssertTrue(lane.doneFolded)
        XCTAssertEqual(lane.doneCount, 3)
        let doneColumns = lane.columns.filter { $0.status == "done" }
        XCTAssertEqual(doneColumns.map(\.key), ["c12", "c13"])
        XCTAssertEqual(doneColumns.map { $0.cards.map(\.id) }, [[3, 1], [2]], "NULL lands in the first done column")
        XCTAssertTrue(doneColumns.allSatisfy { lane.cards($0, unfolded: false).isEmpty })
        XCTAssertEqual(doneColumns.map { lane.cards($0, unfolded: true).count }, [2, 1])
        XCTAssertTrue(lane.hasVisibleCards, "the todo card")
    }

    func testOtherColumnKeepsItsKeyAndRefusesDrops() throws {
        let board = WorkbenchBoardKanban(
            [node(1, status: "snoozed"), node(2, status: "in_progress")], scopeID: nil, showDone: false, columns: def
        )
        let other = try XCTUnwrap(board.columns.last)
        XCTAssertEqual(other.key, WorkbenchBoardKanban.otherStatus)
        XCTAssertEqual(other.cards.map(\.id), [1])
        XCTAssertFalse(other.acceptsDrops)
        XCTAssertNil(other.columnID)
    }
}
