import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Task 10: the Agent Settings sheet's instructions state is kept per workbench.
@MainActor
final class WorkbenchInstructionsViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchInstructionsViewModelTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func json(session: String, wb: Int64) -> Data {
        let global = #""global":{"session":"g","procedure":""}"#
        let own = #""workbench":{"id":\#(wb),"session":"\#(session)","procedure":""}"#
        return Data(#"{"ok":true,"limit":1000,\#(global),\#(own),"suggestions":[]}"#.utf8)
    }

    func testLoadStoresStatePerWorkbench() async {
        let runner = FakeCLIRunner(stdout: json(session: "mine", wb: 7))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        await vm.loadInstructions(projectID: 7)
        XCTAssertEqual(vm.instructions[7]?.workbench?.session, "mine")
        XCTAssertNil(vm.instructions[8])
        XCTAssertEqual(runner.invocations, [["instructions", "show", "--workbench", "7", "--json"]])
    }

    func testSaveRefusalKeepsDraftAndShowsError() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "session instructions: over the limit\n"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        let saved = await vm.saveInstruction(projectID: 7, field: .session, body: "too long")
        XCTAssertFalse(saved)
        XCTAssertEqual(vm.instructionErrors[7]?[.session], "session instructions: over the limit")
        XCTAssertNil(vm.instructions[7])
    }
}
