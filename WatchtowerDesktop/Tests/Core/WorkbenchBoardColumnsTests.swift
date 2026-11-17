import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The board column definition read and the cards' effective column (board
/// #267, PROJ-19). The owner's column moves are Go's (`targets.set_column`);
/// their guards are `internal/db`'s `TestProj19_*`.
final class WorkbenchBoardColumnsTests: XCTestCase {
    private func insertColumn(
        _ db: Database, projectID: Int64, status: String, title: String, position: Int, description: String = ""
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO workbench_board_columns (project_id, status, title, description, position, created_at)
                VALUES (?, ?, ?, ?, ?, '2026-10-16T10:00:00Z')
                """,
            arguments: [projectID, status, title, description, position]
        )
        return db.lastInsertedRowID
    }

    func testCardCountsFollowTheEffectiveColumn() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let spec = try insertColumn(db, projectID: pid, status: "in_progress", title: "Spec", position: 0)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 1)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            let coded = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            try db.execute(sql: "UPDATE targets SET board_column_id = ? WHERE id = ?", arguments: [code, coded])
            let parent = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "todo", parentID: parent)

            let counts = try WorkbenchQueries.boardColumnCardCounts(db, projectID: pid)

            XCTAssertEqual(counts, [spec: 1, code: 1], "NULL → the first column; a parent is no card")
        }
    }

    // MARK: - Reads

    func testBoardColumnsReadsTheDefinitionInStatusOrderThenPosition() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            XCTAssertEqual(try WorkbenchQueries.boardColumns(db, projectID: pid), .empty)

            let shipped = try insertColumn(db, projectID: pid, status: "done", title: "Shipped", position: 0)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 1, description: "d")
            let spec = try insertColumn(db, projectID: pid, status: "in_progress", title: "Spec", position: 0)
            try db.execute(
                sql: "UPDATE projects SET board_hidden_statuses = ? WHERE id = ?",
                arguments: [#"["blocked","in_review"]"#, pid]
            )

            let def = try WorkbenchQueries.boardColumns(db, projectID: pid)
            XCTAssertEqual(def.columns, [
                WorkbenchBoardColumnDef(id: spec, status: "in_progress", title: "Spec", description: "", position: 0),
                WorkbenchBoardColumnDef(id: code, status: "in_progress", title: "Code", description: "d", position: 1),
                WorkbenchBoardColumnDef(id: shipped, status: "done", title: "Shipped", description: "", position: 0)
            ])
            XCTAssertEqual(def.hidden, ["in_review", "blocked"], "normalized to the hideable order")
        }
    }

    func testBoardColumnsRefusesUndecodableHiddenStatuses() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            try db.execute(sql: "UPDATE projects SET board_hidden_statuses = 'nope' WHERE id = ?", arguments: [pid])
            XCTAssertThrowsError(try WorkbenchQueries.boardColumns(db, projectID: pid))
            XCTAssertThrowsError(try WorkbenchQueries.boardColumns(db, projectID: 999_999)) {
                XCTAssertEqual($0 as? WorkbenchQueryError, .workbenchNotFound)
            }
        }
    }

    func testBoardFillsTheNodesColumnID() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 0)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            let plain = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            try db.execute(sql: "UPDATE targets SET board_column_id = ? WHERE id = ?", arguments: [code, target])

            let nodes = try WorkbenchQueries.board(db, projectID: pid)
            XCTAssertEqual(nodes.first { $0.id == Int(target) }?.boardColumnID, code)
            XCTAssertNil(try XCTUnwrap(nodes.first { $0.id == Int(plain) }).boardColumnID)
        }
    }

    func testDefinitionDecodesTheCLIJSON() throws {
        let json = #"{"columns":[{"id":7,"status":"todo","title":"Ready","description":"","position":0},"# +
            #"{"status":"done","title":"Shipped","description":"x","position":0}],"hidden":["blocked"]}"#
        let def = try JSONDecoder().decode(WorkbenchBoardColumns.self, from: Data(json.utf8))
        XCTAssertEqual(def.columns.map(\.id), [7, nil])
        XCTAssertEqual(def.columns.map(\.title), ["Ready", "Shipped"])
        XCTAssertEqual(def.hidden, ["blocked"])
    }
}
