import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The owner's column moves and the column definition read (board #267,
/// PROJ-19): status and column in one statement, the triggers' guard.
final class WorkbenchBoardColumnWritesTests: XCTestCase {
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

    private func history(_ db: Database, _ id: Int64) throws -> [Row] {
        try Row.fetchAll(
            db, sql: "SELECT to_status, actor FROM target_status_history WHERE target_id = ? ORDER BY id", arguments: [id]
        )
    }

    private func placement(_ db: Database, _ id: Int64) throws -> (String?, Int64?) {
        let row = try XCTUnwrap(Row.fetchOne(
            db, sql: "SELECT status, board_column_id FROM targets WHERE id = ?", arguments: [id]
        ))
        return (row["status"], row["board_column_id"])
    }

    func testMoveToColumnWritesStatusAndColumnOnce() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 0)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)
            let before = try history(db, target).count

            let write = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "in_progress", columnID: code)

            XCTAssertEqual(write, WorkbenchOwnerWrite(target: target, rolledUp: []))
            let (status, column) = try placement(db, target)
            XCTAssertEqual(status, "in_progress")
            XCTAssertEqual(column, code)
            let rows = try history(db, target)
            XCTAssertEqual(rows.count, before + 1, "one status change, one history row")
            XCTAssertEqual(rows.last?["to_status"] as String?, "in_progress")
            XCTAssertEqual(rows.last?["actor"] as String?, "owner", "PROJ-06: the owner's move")
        }
    }

    func testMoveToColumnReportsTheRolledUpParents() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let shipped = try insertColumn(db, projectID: pid, status: "done", title: "Shipped", position: 0)
            let root = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Plan")
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, parentID: root)

            let write = try WorkbenchOwnerWrites.moveToColumn(db, targetID: leaf, status: "done", columnID: shipped)

            XCTAssertEqual(write.touched, [leaf, root], "PROJ-05: the parent closes with it")
        }
    }

    func testMoveBetweenColumnsOfOneStatusWritesNoHistory() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let spec = try insertColumn(db, projectID: pid, status: "in_progress", title: "Spec", position: 0)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 1)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "in_progress", columnID: spec)
            let before = try history(db, target).count

            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "in_progress", columnID: code)
            XCTAssertEqual(try placement(db, target).1, code)
            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "in_progress", columnID: nil)
            XCTAssertNil(try placement(db, target).1, "nil = the status's first column")

            XCTAssertEqual(try history(db, target).count, before, "PROJ-06: a column move is not a status change")
        }
    }

    /// A move between two columns of one status is not a status write: the
    /// progress the agent set, the status and its claim stay as they were.
    func testMoveWithinOneStatusKeepsProgress() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let spec = try insertColumn(db, projectID: pid, status: "in_progress", title: "Spec", position: 0)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 1)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            try db.execute(
                sql: "UPDATE targets SET progress = 0.7, board_column_id = ?, updated_at = '2026-10-01T00:00:00Z' WHERE id = ?",
                arguments: [spec, target]
            )

            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "in_progress", columnID: code)

            let row = try XCTUnwrap(Row.fetchOne(
                db, sql: "SELECT status, progress, status_actor, board_column_id, updated_at FROM targets WHERE id = ?",
                arguments: [target]
            ))
            XCTAssertEqual(row["board_column_id"] as Int64?, code)
            XCTAssertEqual(row["status"] as String?, "in_progress")
            XCTAssertEqual(row["progress"] as Double?, 0.7, "a column move keeps the progress")
            XCTAssertNil(row["status_actor"] as String?, "no status claim left behind")
            XCTAssertNotEqual(row["updated_at"] as String?, "2026-10-01T00:00:00Z", "the board's poll sees the move")

            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "done", columnID: nil)
            XCTAssertEqual(
                try Double.fetchOne(db, sql: "SELECT progress FROM targets WHERE id = ?", arguments: [target]), 1.0,
                "a status change still sets the status's progress"
            )
        }
    }

    func testCardCountsFollowTheEffectiveColumn() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let spec = try insertColumn(db, projectID: pid, status: "in_progress", title: "Spec", position: 0)
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 1)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            let coded = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: coded, status: "in_progress", columnID: code)
            let parent = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "todo", parentID: parent)

            let counts = try WorkbenchQueries.boardColumnCardCounts(db, projectID: pid)

            XCTAssertEqual(counts, [spec: 1, code: 1], "NULL → the first column; a parent is no card")
        }
    }

    func testMismatchedColumnIsRefusedByTheTrigger() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let pid = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            let code = try insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 0)
            let foreign = try insertColumn(db, projectID: other, status: "todo", title: "Ready", position: 0)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: pid)

            for (status, column) in [("todo", code), ("todo", foreign)] {
                XCTAssertThrowsError(
                    try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: status, columnID: column)
                ) { error in
                    XCTAssertTrue(
                        String(describing: error).contains("board column does not match the target"), "\(error)"
                    )
                }
            }
            let (status, column) = try placement(db, target)
            XCTAssertEqual(status, "todo")
            XCTAssertNil(column)
        }
    }

    func testMoveToColumnOnAMissingTargetThrows() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            XCTAssertThrowsError(
                try WorkbenchOwnerWrites.moveToColumn(db, targetID: 999_999, status: "done", columnID: nil)
            ) {
                XCTAssertTrue($0 is TargetNotFoundError, "\($0)")
            }
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
            _ = try WorkbenchOwnerWrites.moveToColumn(db, targetID: target, status: "in_progress", columnID: code)

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
