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

/// The drift popover's Fix: one new agent session with the fix prompt, and
/// "Fixing…" (the live session opened, none started) while it runs.
@MainActor
final class WorkbenchesViewModelDriftFixTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelDriftFixTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt fix \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("acme"), withIntermediateDirectories: true)
        processes = []
        center = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    private func finding(_ id: Int64, _ kind: String = "merged_but_open") throws -> WorkbenchDriftFinding {
        let json = #"{"target_id":\#(id),"title":"t","kind":"\#(kind)","detail":"d","fix":"f"}"#
        return try JSONDecoder().decode(WorkbenchDriftFinding.self, from: Data(json.utf8))
    }

    private func setUpBoard() async throws -> (project: Int64, targets: [Int64]) {
        let acme = folder.appendingPathComponent("acme").path
        return try await pool.write {
            let p = try TestDatabase.insertWorkbench($0, name: "acme", folder: acme)
            return (p, [try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "One"),
                        try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Two")])
        }
    }

    func testFixStartsOneSessionWithThePromptAndASecondPressOpensItInstead() async throws {
        let (p, t) = try await setUpBoard()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        let findings = [try finding(t[0]), try finding(t[1], "stale")]

        await vm.fixDrift(projectID: p, findings: findings)
        XCTAssertEqual(processes.count, 1)
        let live = try XCTUnwrap(vm.liveDriftFix(projectID: p))
        XCTAssertEqual(center.states[live], .running)
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: p) }
        XCTAssertEqual(rows.map(\.title), [WorkbenchesViewModel.driftFixTitle])
        let prompt = TerminalLaunch.driftFixPrompt(workbenchID: p, findings: findings)
        XCTAssertEqual(processes.flatMap(\.launches).last?.environment.last, "WATCHTOWER_FIRST_PROMPT=\(prompt)")
        XCTAssertTrue(prompt.contains("#\(t[1]) no movement"))

        await vm.fixDrift(projectID: p, findings: findings)
        XCTAssertEqual(processes.count, 1, "Fixing… opens the live session, no second one")
        let after = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: p) }
        XCTAssertEqual(after.count, 1)
    }

    func testARowFixStartsASessionForThatTargetOnly() async throws {
        let (p, t) = try await setUpBoard()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        let findings = [try finding(t[0]), try finding(t[1])]

        await vm.fixDrift(projectID: p, findings: findings, targetID: t[0])
        XCTAssertNotNil(vm.liveDriftFix(projectID: p, targetID: t[0]))
        XCTAssertNil(vm.liveDriftFix(projectID: p, targetID: t[1]), "the other row still offers Fix")
        XCTAssertNotNil(vm.liveDriftFix(projectID: p), "the header reads Fixing… while any fix runs")
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: p) }
        XCTAssertEqual(rows.first?.targetID, t[0])
    }

    func testAFinishedFixSessionIsNoLongerLive() async throws {
        let (p, t) = try await setUpBoard()
        let vm = makeVM()
        vm.selectedWorkbenchID = p
        await vm.fixDrift(projectID: p, findings: [try finding(t[0])])
        let live = try XCTUnwrap(vm.liveDriftFix(projectID: p))
        await center.close(sessionID: live)
        XCTAssertNil(vm.liveDriftFix(projectID: p))
    }
}
