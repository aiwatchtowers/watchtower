import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The board drift check (PROJ-07) as the Workbench tab runs it.
@MainActor
final class WorkbenchesViewModelDriftTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelDriftTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func report(_ id: Int64, findings: Int) -> Data {
        let items = (0..<findings).map { i in
            #"{"target_id":\#(i + 1),"title":"t","status":"in_progress","kind":"merged_but_open","detail":"d","fix":"f"}"#
        }
        return Data(#"{"project_id":\#(id),"git":true,"base":"main","findings":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    func testRefreshRunsTheOfflineCheckAndKeysTheResultByProject() async {
        let runner = ScriptedCLIRunner(results: [.success(report(1, findings: 2))])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        await vm.refreshDrift(projectID: 1, force: true)
        XCTAssertEqual(runner.invocations, [["workbench", "check", "--workbench", "1", "--json", "--no-network"]])
        XCTAssertEqual(vm.drift[1]?.findings.count, 2)
        XCTAssertNil(vm.drift[2])
    }

    func testPollTicksAreThrottledButTheOwnersRefreshIsNot() async {
        let runner = ScriptedCLIRunner(results: [
            .success(report(1, findings: 1)), .success(report(1, findings: 0)), .success(report(1, findings: 3))
        ])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        let t0 = Date()
        await vm.refreshDrift(projectID: 1, force: true, now: t0)
        await vm.refreshDrift(projectID: 1, now: t0.addingTimeInterval(5))
        XCTAssertEqual(runner.invocations.count, 1, "a poll tick within the interval runs no second check")
        await vm.refreshDrift(projectID: 1, now: t0.addingTimeInterval(WorkbenchesViewModel.driftMinInterval + 1))
        XCTAssertEqual(vm.drift[1]?.findings.count, 0)
        await vm.refreshDrift(projectID: 1, force: true, now: t0.addingTimeInterval(WorkbenchesViewModel.driftMinInterval + 2))
        XCTAssertEqual(vm.drift[1]?.findings.count, 3, "Refresh always runs")
    }

    func testAFailedCheckKeepsTheLastResultAndTheNextSuccessClearsTheError() async {
        let runner = ScriptedCLIRunner(results: [
            .success(report(1, findings: 1)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "folder missing")),
            .success(report(1, findings: 0))
        ])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        await vm.refreshDrift(projectID: 1, force: true)
        await vm.refreshDrift(projectID: 1, force: true)
        XCTAssertNotNil(vm.driftErrors[1])
        XCTAssertEqual(vm.drift[1]?.findings.count, 1, "the last known result stays")
        XCTAssertNil(vm.errorMessage, "never the list-wide error line")
        await vm.refreshDrift(projectID: 1, force: true)
        XCTAssertNil(vm.driftErrors[1])
    }

    /// House rule: a check started, then the owner left — the result still
    /// lands, on the project it belongs to.
    func testAResultArrivingAfterTheOwnerSwitchedProjectsLandsOnItsOwn() async {
        let held = HeldCLIRunner(stdout: report(1, findings: 2))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: held), defaults: defaults)
        vm.selectedWorkbenchID = 1
        let check = Task { await vm.refreshDrift(projectID: 1, force: true) }
        await awaitStarted(held)
        vm.selectedWorkbenchID = 2
        held.release()
        await check.value
        XCTAssertEqual(vm.drift[1]?.findings.count, 2)
        XCTAssertNil(vm.drift[2])
    }
}
