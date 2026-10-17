import XCTest
@testable import WatchtowerCore

/// The Board Columns… sheet's editable state (board #267, spec 2026-10-16
/// §6): the client-side twin of Go `validateBoardColumns`, so the sheet
/// shows a refusal before Save.
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
        draft.move(in: "in_progress", fromOffsets: IndexSet(integer: 1), toOffset: 0)

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
}
