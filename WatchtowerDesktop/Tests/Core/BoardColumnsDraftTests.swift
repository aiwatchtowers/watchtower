import XCTest
@testable import WatchtowerCore

/// The column definition edited on the Kanban's header row (board #267,
/// #713 AI-14 §1): the client-side twin of Go `validateBoardColumns`, so the
/// board shows a refusal without a write, and the in-place operations.
final class BoardColumnsDraftTests: XCTestCase {
    private func column(_ id: Int64?, _ status: String, _ title: String, _ position: Int = 0) -> WorkbenchBoardColumnDef {
        WorkbenchBoardColumnDef(id: id, status: status, title: title, description: "", position: position)
    }

    func testDraftRejectsSeventhColumnInAStatus() {
        var draft = BoardColumnsDraft(.empty)
        for _ in 0..<6 { draft.add(to: "in_progress") }
        XCTAssertEqual(draft.errors, [], "six columns in one status are allowed")
        XCTAssertFalse(draft.canAdd(to: "in_progress"))
        XCTAssertTrue(draft.canAdd(to: "todo"))

        draft.add(to: "in_progress")

        XCTAssertEqual(draft.errors, ["In Progress: at most 6 columns"])
    }

    func testDraftRejectsDigitOnlyTitle() {
        var draft = BoardColumnsDraft(.empty)
        let id = draft.add(to: "todo")
        draft.setTitle(" 12 ", of: id)
        XCTAssertEqual(draft.errors, ["“12”: a title cannot be only digits"])

        draft.setTitle("Phase 2", of: id)
        XCTAssertEqual(draft.errors, [])
    }

    func testDraftRejectsTitleEqualToAnotherStatusLabel() {
        var draft = BoardColumnsDraft(.empty)
        let id = draft.add(to: "todo")
        draft.setTitle("  done ", of: id)
        XCTAssertEqual(draft.errors, ["“done” is the name of another status (Done)"])

        draft.setTitle("To Do", of: id)
        XCTAssertEqual(draft.errors, [], "a status's own label is a fine title for its column")

        let other = draft.add(to: "in_progress")
        draft.setTitle("to do", of: other)
        XCTAssertEqual(draft.errors, [
            "“to do” is the name of another status (To Do)",
            "“to do” is used twice"
        ])
    }

    func testDraftRejectsHideWithColumns() throws {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(columns: [column(4, "blocked", "Waiting")], hidden: []))
        XCTAssertFalse(draft.canHide("blocked"), "a status with columns cannot be hidden")
        XCTAssertTrue(draft.canHide("in_review"))
        XCTAssertFalse(draft.canHide("todo"), "only in_review and blocked are hideable")

        draft.setHidden(true, for: "blocked")
        XCTAssertEqual(draft.errors, ["Blocked cannot be hidden while it has columns"])

        draft.delete(try XCTUnwrap(draft.columns(of: "blocked").first).id)
        XCTAssertEqual(draft.errors, [])
        XCTAssertTrue(draft.canHide("blocked"))
        XCTAssertFalse(draft.canAdd(to: "blocked"), "a hidden status takes no columns")
    }

    func testDraftKeepsIDsOnRename() throws {
        let def = WorkbenchBoardColumns(
            columns: [column(7, "in_progress", "Spec", 0), column(9, "in_progress", "Code", 1)],
            hidden: ["in_review"]
        )
        var draft = BoardColumnsDraft(def)
        XCTAssertEqual(draft.definition, def, "an untouched draft is the stored definition")

        let spec = try XCTUnwrap(draft.columns(of: "in_progress").first)
        draft.setTitle("Design", of: spec.id)
        draft.move(9, by: -1)

        XCTAssertEqual(draft.definition.columns, [
            column(9, "in_progress", "Code", 0),
            column(7, "in_progress", "Design", 1)
        ])
        XCTAssertEqual(draft.definition.hidden, ["in_review"])
    }

    func testDraftEncodesTheCLIJSON() throws {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(columns: [column(3, "todo", "Ready")], hidden: []))
        let new = draft.add(to: "done")
        draft.setTitle(" Shipped ", of: new)
        draft.setDescription("Merged and released", of: new)
        draft.setHidden(true, for: "blocked")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["columns", "hidden"])
        XCTAssertEqual(object["hidden"] as? [String], ["blocked"])
        let columns = try XCTUnwrap(object["columns"] as? [[String: Any]])
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(Set(columns[0].keys), ["id", "status", "title", "description", "position"])
        XCTAssertEqual(columns[0]["id"] as? Int, 3)
        XCTAssertEqual(Set(columns[1].keys), ["status", "title", "description", "position"], "a new column has no id")
        XCTAssertEqual(columns[1]["status"] as? String, "done")
        XCTAssertEqual(columns[1]["title"] as? String, "Shipped")
        XCTAssertEqual(columns[1]["description"] as? String, "Merged and released")
        XCTAssertEqual(columns[1]["position"] as? Int, 0)
    }

    func testDeleteNoticeCountsCards() throws {
        let def = WorkbenchBoardColumns(
            columns: [column(7, "in_progress", "Spec", 0), column(9, "in_progress", "Code", 1)], hidden: []
        )
        let draft = BoardColumnsDraft(def)
        let columns = draft.columns(of: "in_progress")
        let counts: [Int64: Int] = [7: 1, 9: 3]

        XCTAssertEqual(draft.deleteNotice(for: columns[1].id, cardCounts: counts), "3 cards move to Spec.")
        XCTAssertEqual(draft.deleteNotice(for: columns[0].id, cardCounts: counts), "1 card moves to Code.")
        XCTAssertNil(draft.deleteNotice(for: columns[0].id, cardCounts: [:]), "an empty column deletes quietly")

        var lone = BoardColumnsDraft(WorkbenchBoardColumns(columns: [column(5, "done", "Shipped")], hidden: []))
        XCTAssertEqual(
            lone.deleteNotice(for: lone.columns(of: "done")[0].id, cardCounts: [5: 2]), "2 cards move to Done.",
            "the last column's cards fall to the status's standard column"
        )
        let new = lone.add(to: "todo")
        XCTAssertNil(lone.deleteNotice(for: new, cardCounts: [5: 2]), "an unsaved column holds no cards")
    }

    // MARK: - Edits on the board (#713 AI-14 §1)

    private func titles(_ draft: BoardColumnsDraft, _ status: String) -> [String] {
        draft.columns(of: status).map(\.title)
    }

    func testRenameOnAnImplicitColumnDefinesTheStatusFirstColumn() {
        var draft = BoardColumnsDraft(.empty)
        draft.rename(nil, in: "in_progress", to: "Coding")
        XCTAssertEqual(draft.definition.columns, [column(nil, "in_progress", "Coding")])

        var stored = BoardColumnsDraft(WorkbenchBoardColumns(columns: [column(4, "todo", "Ready")], hidden: []))
        stored.rename(4, in: "todo", to: " Next ")
        XCTAssertEqual(stored.definition.columns, [column(4, "todo", "Next")], "a stored column keeps its id")
    }

    func testDescriptionOnAnImplicitColumnDefinesItUnderTheStatusLabel() {
        var draft = BoardColumnsDraft(.empty)
        draft.describe(nil, in: "done", as: "Merged")
        XCTAssertEqual(draft.definition.columns, [
            WorkbenchBoardColumnDef(id: nil, status: "done", title: "Done", description: "Merged", position: 0)
        ])
    }

    func testAddingBesideAnImplicitColumnDefinesTwo() {
        var draft = BoardColumnsDraft(.empty)
        let new = draft.insertColumn(beside: nil, in: "todo", after: true)
        XCTAssertEqual(titles(draft, "todo"), ["To Do", "New Column"],
                       "the status-named column comes first, so it keeps the cards")
        XCTAssertEqual(draft.columns(of: "todo").last?.id, new)
        XCTAssertEqual(draft.errors, [])
    }

    func testInsertLeftAndRightOfAStoredColumn() {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(
            columns: [column(1, "in_progress", "Spec", 0), column(2, "in_progress", "Code", 1)], hidden: []
        ))
        let right = draft.insertColumn(beside: 1, in: "in_progress", after: true)
        XCTAssertEqual(titles(draft, "in_progress"), ["Spec", "New Column", "Code"])
        draft.rename(nil, in: "in_progress", to: "ignored")
        XCTAssertEqual(titles(draft, "in_progress"), ["Spec", "New Column", "Code"],
                       "a status with columns has no implicit one to rename")
        draft.insertColumn(beside: 1, in: "in_progress", after: false)
        XCTAssertEqual(titles(draft, "in_progress"), ["New Column 2", "Spec", "New Column", "Code"])
        XCTAssertEqual(draft.columns(of: "in_progress")[2].id, right)
    }

    func testAppendColumnToAStatus() {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(columns: [column(1, "todo", "Ready")], hidden: []))
        draft.appendColumn(to: "todo")
        XCTAssertEqual(titles(draft, "todo"), ["Ready", "New Column"])
        draft.appendColumn(to: "blocked")
        XCTAssertEqual(titles(draft, "blocked"), ["Blocked", "New Column 2"], "an implicit status gets two")
    }

    func testAddOnAHiddenStatusOrPastTheLimitIsRefusedByErrors() {
        var hidden = BoardColumnsDraft(WorkbenchBoardColumns(columns: [], hidden: ["in_review"]))
        XCTAssertFalse(hidden.canAdd(to: "in_review"))
        hidden.appendColumn(to: "in_review")
        XCTAssertEqual(hidden.errors, ["In Review cannot be hidden while it has columns"])

        var full = BoardColumnsDraft(.empty)
        for _ in 0..<5 { full.appendColumn(to: "todo") }
        XCTAssertEqual(full.columns(of: "todo").count, 6)
        full.insertColumn(beside: full.columns(of: "todo")[0].columnID, in: "todo", after: true)
        XCTAssertEqual(full.errors, ["To Do: at most 6 columns"])
    }

    func testMoveStaysInsideItsStatus() {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(columns: [
            column(1, "todo", "Ready", 0),
            column(2, "in_progress", "Spec", 0), column(3, "in_progress", "Code", 1)
        ], hidden: []))
        XCTAssertFalse(draft.canMove(2, by: -1), "the status's first column has no left within its status")
        XCTAssertTrue(draft.canMove(2, by: 1))
        XCTAssertFalse(draft.canMove(3, by: 1))
        XCTAssertFalse(draft.canMove(1, by: 1), "a lone column cannot move")

        draft.move(2, by: 1)
        XCTAssertEqual(draft.definition.columns, [
            column(1, "todo", "Ready", 0), column(3, "in_progress", "Code", 0), column(2, "in_progress", "Spec", 1)
        ])
        draft.move(2, by: 1)
        XCTAssertEqual(titles(draft, "in_progress"), ["Code", "Spec"], "past the edge nothing moves")
    }

    func testDeletingTheLastColumnReturnsTheStatusToImplicit() {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(
            columns: [column(1, "done", "Shipped", 0), column(2, "done", "Released", 1)], hidden: []
        ))
        draft.deleteColumn(1)
        XCTAssertEqual(titles(draft, "done"), ["Released"])
        draft.deleteColumn(2)
        XCTAssertEqual(draft.definition, .empty)
        draft.deleteColumn(99)
        XCTAssertEqual(draft.definition, .empty, "a stale id deletes nothing")
    }

    func testHideAndShowOnTheBoard() {
        var draft = BoardColumnsDraft(.empty)
        XCTAssertTrue(draft.canHide("blocked"))
        draft.setHidden(true, for: "blocked")
        XCTAssertEqual(draft.definition.hidden, ["blocked"])
        draft.setHidden(false, for: "blocked")
        XCTAssertEqual(draft.definition.hidden, [])
    }

    func testStoredIDOfANewColumnAfterSave() {
        var draft = BoardColumnsDraft(WorkbenchBoardColumns(columns: [column(1, "todo", "Ready")], hidden: []))
        let new = draft.insertColumn(beside: 1, in: "todo", after: false)
        let saved = WorkbenchBoardColumns(
            columns: [column(8, "todo", "New Column", 0), column(1, "todo", "Ready", 1)], hidden: []
        )
        XCTAssertEqual(draft.storedID(of: new, in: saved), 8)
        XCTAssertNil(draft.storedID(of: 42, in: saved))
    }

    func testDeleteNoticeByStoredColumn() {
        let draft = BoardColumnsDraft(WorkbenchBoardColumns(
            columns: [column(7, "in_progress", "Spec", 0), column(9, "in_progress", "Code", 1)], hidden: []
        ))
        XCTAssertEqual(draft.deleteNotice(forStored: 9, cardCounts: [9: 2]), "2 cards move to Spec.")
        XCTAssertNil(draft.deleteNotice(forStored: 7, cardCounts: [9: 2]))
    }
}
