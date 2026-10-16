import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board #267: the Board Columns… sheet reads and saves through
/// `watchtower workbench columns`, and shows Go's refusal as it is.
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

    func testLoadReadsTheDefinitionAndTheCardsPerColumn() async throws {
        let (pid, code) = try await pool.write { db -> (Int64, Int64) in
            let pid = try TestDatabase.insertWorkbench(db)
            try db.execute(
                sql: """
                    INSERT INTO workbench_board_columns (project_id, status, title, description, position, created_at)
                    VALUES (?, 'in_progress', 'Code', '', 0, '2026-10-16T10:00:00Z')
                    """,
                arguments: [pid]
            )
            let code = db.lastInsertedRowID
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, status: "in_progress")
            return (pid, code)
        }
        let json = #"{"columns":[{"id":\#(code),"status":"in_progress","title":"Code","description":"","position":0}],"hidden":[]}"#
        let runner = FakeCLIRunner(stdout: Data(json.utf8))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)

        let (def, counts) = try await vm.loadBoardColumns(projectID: pid)

        XCTAssertEqual(def.columns.map(\.title), ["Code"])
        XCTAssertEqual(counts, [code: 1])
        XCTAssertEqual(runner.invocations, [["workbench", "columns", String(pid), "--json"]])
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
