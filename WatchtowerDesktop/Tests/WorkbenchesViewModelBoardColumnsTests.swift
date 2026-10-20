import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board #267, #713 AI-14 §1: the columns are edited on the Kanban's header
/// row — every edit saves the whole definition through `watchtower workbench
/// columns --set -`, and a refusal (the draft's or Go's) shows as it is.
@MainActor
final class WorkbenchesViewModelBoardColumnsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelBoardColumnsTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    nonisolated private static func insertColumn(_ db: Database, projectID: Int64, status: String, title: String, position: Int) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO workbench_board_columns (project_id, status, title, description, position, created_at)
                VALUES (?, ?, ?, '', ?, '2026-10-16T10:00:00Z')
                """,
            arguments: [projectID, status, title, position]
        )
        return db.lastInsertedRowID
    }

    private func boardVM(_ pid: Int64) -> WorkbenchBoardViewModel {
        let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: pid, defaults: defaults)
        vm.load()
        return vm
    }

    func testAnEditSavesTheWholeDefinitionAndOpensTheNewColumnInRename() async throws {
        let (pid, ready) = try await pool.write { db -> (Int64, Int64) in
            let pid = try TestDatabase.insertWorkbench(db)
            return (pid, try Self.insertColumn(db, projectID: pid, status: "todo", title: "Ready", position: 0))
        }
        let vm = boardVM(pid)
        var sent: [WorkbenchBoardColumns] = []
        vm.saveColumns = { def in
            sent.append(def)
            return WorkbenchBoardColumns(columns: [
                WorkbenchBoardColumnDef(id: ready, status: "todo", title: "Ready", description: "", position: 0),
                WorkbenchBoardColumnDef(id: 41, status: "todo", title: "New Column", description: "", position: 1)
            ], hidden: [])
        }

        let saved = await vm.editColumns { $0.insertColumn(beside: ready, in: "todo", after: true) }

        XCTAssertTrue(saved)
        XCTAssertEqual(sent.map { $0.columns.map(\.title) }, [["Ready", "New Column"]])
        XCTAssertEqual(sent.first?.columns.first?.id, ready, "the stored column keeps its id")
        XCTAssertEqual(vm.renamingColumnKey, BoardColumnLayout.key(41))
        XCTAssertNil(vm.columnsError)
    }

    func testADraftRefusalWritesNothing() async throws {
        let pid = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let vm = boardVM(pid)
        var calls = 0
        vm.saveColumns = { def in
            calls += 1
            return def
        }

        let saved = await vm.editColumns { $0.rename(nil, in: "todo", to: "Done"); return nil }

        XCTAssertFalse(saved)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(vm.columnsError, "“Done” is the name of another status (Done)")
        XCTAssertEqual(vm.boardColumns, .empty)

        _ = await vm.editColumns { $0.rename(nil, in: "todo", to: "Ready"); return nil }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(vm.columnsError, "the next edit clears the refusal")
    }

    func testGosRefusalShowsUnderTheHeaderRow() async throws {
        let pid = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let vm = boardVM(pid)
        vm.saveColumns = { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "status todo: at most 6 columns\n") }

        let saved = await vm.editColumns { $0.appendColumn(to: "todo") }

        XCTAssertFalse(saved)
        XCTAssertEqual(vm.columnsError, "status todo: at most 6 columns")
        XCTAssertNil(vm.renamingColumnKey)
    }

    func testAnEditThatChangesNothingDoesNotWrite() async throws {
        let pid = try await pool.write { db -> Int64 in
            let pid = try TestDatabase.insertWorkbench(db)
            _ = try Self.insertColumn(db, projectID: pid, status: "todo", title: "Ready", position: 0)
            return pid
        }
        let vm = boardVM(pid)
        var calls = 0
        vm.saveColumns = { def in
            calls += 1
            return def
        }
        let id = try XCTUnwrap(vm.boardColumns.columns.first?.id)

        let saved = await vm.editColumns { $0.rename(id, in: "todo", to: " Ready "); return nil }
        XCTAssertTrue(saved)
        XCTAssertEqual(calls, 0)
    }

    func testWithoutAWriterTheEditIsRefused() async throws {
        let pid = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let vm = boardVM(pid)

        let saved = await vm.editColumns { $0.appendColumn(to: "todo") }
        XCTAssertFalse(saved)
        XCTAssertEqual(vm.columnsError, "The watchtower command-line tool is not available.")
    }

    func testDeleteNoticeCountsTheColumnsCards() async throws {
        let (pid, spec, code) = try await pool.write { db -> (Int64, Int64, Int64) in
            let pid = try TestDatabase.insertWorkbench(db)
            let spec = try Self.insertColumn(db, projectID: pid, status: "in_progress", title: "Spec", position: 0)
            let code = try Self.insertColumn(db, projectID: pid, status: "in_progress", title: "Code", position: 1)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            return (pid, spec, code)
        }
        let vm = boardVM(pid)

        XCTAssertEqual(vm.columnDeleteNotice(spec), "1 card moves to Code.",
                       "a card with no stored column shows in the first column")
        XCTAssertNil(vm.columnDeleteNotice(code))
    }

    func testEditColumnsOnTheKanbanShowsTheBoardAndAsksForKanbanOnce() {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)

        vm.editColumnsOnKanban(projectID: 7)

        XCTAssertTrue(vm.layout(projectID: 7).isShowing(.board))
        XCTAssertTrue(vm.takeKanbanRequest(projectID: 7))
        XCTAssertFalse(vm.takeKanbanRequest(projectID: 7))
    }

    func testARefusedSaveShowsGosMessage() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "status todo: at most 6 columns\n"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        do {
            _ = try await vm.saveBoardColumns(.empty, projectID: 7)
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(WorkbenchesViewModel.boardColumnsMessage(error), "status todo: at most 6 columns")
        }
        XCTAssertEqual(runner.stdinInputs.count, 1)
    }

    func testWithoutTheCLINothingRuns() async {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        do {
            _ = try await vm.saveBoardColumns(.empty, projectID: 7)
            XCTFail("expected cliUnavailable")
        } catch {
            XCTAssertEqual(
                WorkbenchesViewModel.boardColumnsMessage(error), "The watchtower command-line tool is not available."
            )
        }
    }
}
