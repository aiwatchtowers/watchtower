import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board #266: the Agent settings keep the CLI's last answer per workbench
/// on the app-wide view model, and show what a call failed to do.
@MainActor
final class WorkbenchesViewModelMethodologyTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelMethodologyTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func viewModel(_ runner: FakeCLIRunner) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    func testLoadKeepsTheStateAndNoError() async {
        let runner = FakeCLIRunner(stdout: Data(WorkbenchMethodologyFixtures.envelope.utf8))
        let vm = viewModel(runner)
        await vm.loadMethodology(projectID: 7)
        XCTAssertEqual(vm.methodology[7]?.effective.askGuard, "soft")
        XCTAssertNil(vm.methodologyErrors[7])
        XCTAssertEqual(runner.invocations.last, ["workbench", "methodology", "7", "--json"])
    }

    func testSetPassesTheFlagAndShowsAFailedInstall() async {
        let failed = WorkbenchMethodologyFixtures.envelope.replacingOccurrences(
            of: #""install_ran":false,"install_ok":true,"install_error":"""#,
            with: #""install_ran":true,"install_ok":false,"install_error":"permission denied""#)
        let runner = FakeCLIRunner(stdout: Data(failed.utf8))
        let vm = viewModel(runner)
        await vm.setMethodology(.preset, to: "none", projectID: 7)
        XCTAssertEqual(runner.invocations.last, ["workbench", "methodology", "7", "--preset=none", "--json"])
        XCTAssertEqual(vm.methodologyErrors[7],
                       "The setting was saved, but the folder's skills were not updated: permission denied. Use Re-run Setup.")
        XCTAssertNotNil(vm.methodology[7], "the CLI's answer is still shown")
    }

    func testACLIFailureKeepsTheLastState() async {
        let runner = FakeCLIRunner(stdout: Data(WorkbenchMethodologyFixtures.envelope.utf8))
        let vm = viewModel(runner)
        await vm.loadMethodology(projectID: 7)
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        await vm.setMethodology(.askGuard, to: "off", projectID: 7)
        XCTAssertNotNil(vm.methodologyErrors[7])
        XCTAssertEqual(vm.methodology[7]?.effective.askGuard, "soft", "nothing changed: the last answer stays")
    }

    func testCreateWorkflowFilePassesTheFlag() async {
        let runner = FakeCLIRunner(stdout: Data(WorkbenchMethodologyFixtures.envelope.utf8))
        let vm = viewModel(runner)
        await vm.createWorkflowFile(projectID: 7)
        XCTAssertEqual(runner.invocations.last, ["workbench", "methodology", "7", "--create-file", "--json"])
    }

    func testNoCLIIsAnError() async {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.loadMethodology(projectID: 7)
        XCTAssertNotNil(vm.methodologyErrors[7])
        XCTAssertNil(vm.methodology[7])
    }
}
