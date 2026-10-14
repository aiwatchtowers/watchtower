import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The automatic cleanup after a finished placed session's agent exits
/// (spec 2026-10-14-session-worktrees-design.md §9): #535's cleanup of
/// exactly that session's worktree and `wt/` branch, then the removed
/// worktree's MCP entry forgotten. No subprocess is spawned: terminals are
/// fake and both runners are doubles.
@MainActor
final class WorkbenchesViewModelPlacedCleanupTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private var processes: [Int64: FakeTerminalSession] = [:]
    private var lastProcess: FakeTerminalSession?
    private var terminals: TerminalCenter!
    private var cli: FakeCLIRunner!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelPlacedCleanupTests-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wt placed \(UUID().uuidString)",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: worktree + "/sub"), withIntermediateDirectories: true)
        terminals = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.lastProcess = process
            return process
        }
        terminals.shell = { "/bin/zsh" }
        terminals.transcriptExists = { _ in true }
        cli = FakeCLIRunner(stdout: Data(#"{"workbench_id":1,"forgot":true,"error":""}"#.utf8))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var acme: String { root.appendingPathComponent("acme").path }
    /// The placed session's worktree root.
    private var worktree: String { acme + "/.claude/worktrees/x" }
    /// Another worktree the session visited, also removable in the plan.
    private var otherWorktree: String { acme + "/.claude/worktrees/y" }

    private func makeVM(_ runner: FakeSessionCleanupRunner) -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: cli), defaults: defaults,
                                      terminalCenter: terminals)
        vm.titleService = { _ in .init(title: "", written: false) }
        let cleanup = SessionCleanupCenter(runner: runner)
        cleanup.liveSessionIDs = { [terminals] in terminals?.liveIDs ?? [] }
        vm.sessionCleanup = cleanup
        return vm
    }

    /// A running claude row of a workbench; placed (in `worktree/sub`, on
    /// `wt/x`) unless `branch` is nil.
    private func runningRow(branch: String? = "wt/x", finished: Bool) async throws -> TerminalSession {
        let main = acme
        let folder = branch == nil ? main : worktree + "/sub"
        let row = try await pool.write { db in
            let p = try TestDatabase.insertWorkbench(db, name: "acme", folder: main)
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: p, kind: .claude, title: "placed", folderPath: folder,
                claudeSessionID: UUID().uuidString.lowercased(), worktreeBranch: branch, worktreeBase: branch.map { _ in "abc" }
            ))
            if finished {
                try db.execute(sql: "UPDATE terminal_sessions SET finished_at = '2026-10-14T12:00:00.000Z' WHERE id = ?",
                               arguments: [row.id])
            }
            return row
        }
        terminals.start(row, fresh: false)
        processes[row.id] = lastProcess
        XCTAssertTrue(terminals.liveIDs.contains(row.id))
        return row
    }

    private func markFinished(_ row: TerminalSession) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET finished_at = '2026-10-14T12:00:00.000Z' WHERE id = ?",
                           arguments: [row.id])
        }
    }

    /// The agent process of `row` exits; returns once the hook's cleanup ran.
    private func exitAgent(_ vm: WorkbenchesViewModel, _ row: TerminalSession) async throws {
        try XCTUnwrap(processes[row.id]).exit(0)
        await vm.placedCleanupRuns[row.id]?.value
    }

    private func item(
        _ key: String,
        _ kind: String,
        action: String = "remove",
        reason: String = "",
        done: Bool = false
    ) -> String {
        #"{"key":"\#(key)","kind":"\#(kind)","name":"n","action":"\#(action)","reason":"\#(reason)","done":\#(done)}"#
    }

    private func plan(_ items: [String], mode: String = "plan") -> Data {
        Data(#"{"session_id":1,"workbench_id":1,"mode":"\#(mode)","items":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    /// The plan Go gives the placed session: its worktree and branch, plus
    /// another worktree and branch it visited, all removable.
    private var fullPlan: Data {
        plan([
            item("worktree:\(otherWorktree)", "worktree"),
            item("worktree:\(worktree)", "worktree"),
            item("branch:wt/x", "branch"),
            item("branch:feat/y", "branch")
        ])
    }

    private func applyCalls(_ runner: FakeSessionCleanupRunner) -> [[String]] {
        runner.calls.map(\.args).filter { $0.contains("--apply") }
    }

    private var forgetCalls: [[String]] {
        cli.invocations.filter { $0.starts(with: ["workbench", "worktree", "forget"]) }
    }

    // MARK: - Tests

    func testFinishedPlacedSessionExitCleansExactlyItsTwoItems() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(fullPlan),
            .success(plan([item("worktree:\(worktree)", "worktree", done: true),
                           item("branch:wt/x", "branch", done: true)], mode: "apply"))
        ])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try await exitAgent(vm, row)

        let planCall = try XCTUnwrap(runner.calls.first?.args)
        XCTAssertFalse(planCall.contains("--apply"))
        XCTAssertTrue(planCall.contains("--session=\(row.id)"))
        XCTAssertFalse(planCall.contains("--live-session=\(row.id)"), "the session's process has exited")
        XCTAssertEqual(applyCalls(runner).count, 1)
        let apply = try XCTUnwrap(applyCalls(runner).first)
        XCTAssertEqual(apply.filter { $0.hasPrefix("--item") }, ["--item=worktree:\(worktree)", "--item=branch:wt/x"],
                       "only the session's own worktree and branch, never another removable item")
        XCTAssertNil(runner.calls.last?.environment[SessionCleanupCenter.terminalSessionVariable])
        XCTAssertEqual(vm.sessionCleanup?.cleanupPhase(for: .session(row.id)), .idle, "the run leaves no phase")
        XCTAssertFalse(vm.cleaningUpSessions.contains(row.id))
        XCTAssertNil(vm.placedCleanupRuns[row.id])
    }

    func testUnfinishedExitDoesNothing() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: false)

        try await exitAgent(vm, row)

        XCTAssertTrue(runner.calls.isEmpty, "a crash or a quit without finish_session cleans nothing")
        XCTAssertTrue(forgetCalls.isEmpty)

        // Positive control: the same row, finished, resumed and exited again.
        try await markFinished(row)
        terminals.start(row, fresh: false)
        try await exitAgent(vm, row)
        XCTAssertEqual(applyCalls(runner).count, 1, "a finished row's exit cleans up")
    }

    func testUnplacedRowExitDoesNothing() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(branch: nil, finished: true)

        try await exitAgent(vm, row)

        XCTAssertTrue(runner.calls.isEmpty, "a session in the workbench folder has no worktree of its own")
        XCTAssertTrue(forgetCalls.isEmpty)
    }

    func testKeptItemsAreNotForgotten() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(plan([
                item("worktree:\(worktree)", "worktree", action: "keep", reason: "uncommitted_changes"),
                item("branch:wt/x", "branch", action: "keep", reason: "checked_out"),
                item("worktree:\(otherWorktree)", "worktree")
            ]))
        ])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try await exitAgent(vm, row)

        XCTAssertEqual(runner.calls.count, 1, "the plan only")
        XCTAssertTrue(applyCalls(runner).isEmpty, "a kept item is never applied, nor anything else")
        XCTAssertTrue(forgetCalls.isEmpty)
    }

    func testRemovedWorktreeIsForgotten() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(plan([item("worktree:\(worktree)", "worktree"),
                           item("branch:wt/x", "branch", action: "keep", reason: "unpushed_commits")])),
            .success(plan([item("worktree:\(worktree)", "worktree", done: true)], mode: "apply"))
        ])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try await exitAgent(vm, row)

        let apply = try XCTUnwrap(applyCalls(runner).first)
        XCTAssertEqual(apply.filter { $0.hasPrefix("--item") }, ["--item=worktree:\(worktree)"])
        XCTAssertEqual(forgetCalls.count, 1)
        let forget = try XCTUnwrap(forgetCalls.first)
        XCTAssertEqual(forget.firstIndex(of: "--path").map { forget[$0 + 1] }, worktree, "the worktree root")
        XCTAssertEqual(forget.firstIndex(of: "--workbench").map { forget[$0 + 1] }, row.projectID.map(String.init))
    }

    func testAWorktreeGoKeptAtApplyIsNotForgotten() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(plan([item("worktree:\(worktree)", "worktree"), item("branch:wt/x", "branch")])),
            .success(plan([item("worktree:\(worktree)", "worktree", action: "keep", reason: "process_running"),
                           item("branch:wt/x", "branch", done: true)], mode: "apply"))
        ])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try await exitAgent(vm, row)

        XCTAssertEqual(applyCalls(runner).count, 1)
        XCTAssertTrue(forgetCalls.isEmpty, "only a removed worktree loses its MCP entry")
    }

    func testAResumeBeforeTheCleanupRunsCancelsIt() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        // Resumed before the hook's task got to run.
        try XCTUnwrap(processes[row.id]).exit(0)
        terminals.start(row, fresh: false)
        await vm.placedCleanupRuns[row.id]?.value

        XCTAssertTrue(runner.calls.isEmpty, "a live row is never cleaned up")
        XCTAssertTrue(terminals.liveIDs.contains(row.id))

        // Positive control: the resumed agent exits by itself later.
        try await exitAgent(vm, row)
        XCTAssertEqual(applyCalls(runner).count, 1)
    }

    func testAResumeWhileThePlanRunsCancelsTheApply() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        runner.holdsCalls = true
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try XCTUnwrap(processes[row.id]).exit(0)
        let deadline = Date().addingTimeInterval(5)
        while runner.heldCount == 0, Date() < deadline { await Task.yield() }
        XCTAssertEqual(runner.heldCount, 1, "the exit started a plan")
        terminals.start(row, fresh: false)
        runner.release()
        await vm.placedCleanupRuns[row.id]?.value

        XCTAssertEqual(runner.calls.count, 1, "the plan ran")
        XCTAssertTrue(applyCalls(runner).isEmpty, "liveness is checked again right before the apply")
        XCTAssertTrue(forgetCalls.isEmpty)
        XCTAssertEqual(vm.sessionCleanup?.cleanupPhase(for: .session(row.id)), .idle)
    }

    func testExactRootSelectionNeverTakesAnEnclosingOrNestedWorktree() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(plan([
                item("worktree:\(acme)/.claude/worktrees", "worktree"),
                item("worktree:\(worktree)/sub", "worktree"),
                item("branch:wt/x", "branch")
            ])),
            .success(plan([item("branch:wt/x", "branch", done: true)], mode: "apply"))
        ])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try await exitAgent(vm, row)

        let apply = try XCTUnwrap(applyCalls(runner).first)
        XCTAssertEqual(apply.filter { $0.hasPrefix("--item") }, ["--item=branch:wt/x"],
                       "only the worktree at the folder's exact worktree top is the session's")
        XCTAssertTrue(forgetCalls.isEmpty)
    }

    func testAnAppClosedTerminalStartsNoCleanup() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)
        let process = try XCTUnwrap(processes[row.id])
        // The process exits during the close's SIGHUP grace.
        let onExit = process.onExit
        await terminals.close(sessionID: row.id)
        onExit?(0)
        await vm.placedCleanupRuns[row.id]?.value

        XCTAssertTrue(runner.calls.isEmpty, "an exit Watchtower caused is not the normal end")
    }

    func testAnExitWhileItsWorkbenchIsDeletedStartsNoCleanup() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)
        let process = try XCTUnwrap(processes[row.id])
        vm.closeTerminal = { [weak vm] _ in
            process.exit(0)
            await vm?.placedCleanupRuns[row.id]?.value
        }

        await vm.deleteWorkbench(try XCTUnwrap(row.projectID))

        XCTAssertTrue(runner.calls.isEmpty, "the workbench delete owns its rows' cleanup")
    }

    func testADeleteDialogPlanReadyFirstIsLeftAlone() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)
        await vm.planCleanupBeforeDelete(row)
        XCTAssertNotNil(vm.deleteCleanupChoice(row))

        try await exitAgent(vm, row)

        XCTAssertEqual(runner.calls.count, 1, "the dialog's plan only")
        XCTAssertTrue(applyCalls(runner).isEmpty)
        XCTAssertNotNil(vm.deleteCleanupChoice(row), "the open dialog keeps its plan")
    }

    func testADeleteDialogPlanStartedDuringTheAutomaticPlanWins() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        runner.holdsCalls = true
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)

        try XCTUnwrap(processes[row.id]).exit(0)
        try await waitForHeld(runner, 1)
        let dialog = Task { await vm.planCleanupBeforeDelete(row) }
        try await waitForHeld(runner, 2)
        runner.release()
        await dialog.value
        await vm.placedCleanupRuns[row.id]?.value

        XCTAssertTrue(applyCalls(runner).isEmpty, "the automatic run never applies another owner's plan")
        XCTAssertNotNil(vm.deleteCleanupChoice(row), "nor forgets it")
    }

    func testDeleteAndCleanUpStartedDuringTheAutomaticPlanAppliesOnce() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(fullPlan),
            .success(plan([item("worktree:\(worktree)", "worktree", done: true)], mode: "apply"))
        ])
        runner.holdsCalls = true
        let vm = makeVM(runner)
        vm.deleteSleep = { _ in }
        let row = try await runningRow(finished: true)

        try XCTUnwrap(processes[row.id]).exit(0)
        try await waitForHeld(runner, 1)
        let choice = SessionDeleteCleanupChoice(plan: SessionCleanupPlan(items: [
            SessionCleanupItem(key: "worktree:\(worktree)", kind: .worktree, action: .remove)
        ]))
        let delete = vm.startDeleteAndCleanUp(row, choice: choice)
        try await waitForHeld(runner, 2)
        XCTAssertTrue(vm.cleaningUpSessions.contains(row.id), "Delete and Clean Up holds the row")
        runner.release()
        await vm.placedCleanupRuns[row.id]?.value
        XCTAssertTrue(vm.cleaningUpSessions.contains(row.id) || vm.cleanupRuns[row.id] == nil,
                      "the automatic run never clears the delete's busy flag")
        let deleted = await delete.value

        XCTAssertTrue(deleted)
        XCTAssertEqual(applyCalls(runner).count, 1, "only Delete and Clean Up's apply")
        XCTAssertEqual(applyCalls(runner).first?.filter { $0.hasPrefix("--item") }, ["--item=worktree:\(worktree)"])
    }

    /// Waits (bounded) until `runner` holds `count` calls.
    private func waitForHeld(_ runner: FakeSessionCleanupRunner, _ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while runner.heldCount < count, Date() < deadline { await Task.yield() }
        XCTAssertEqual(runner.heldCount, count)
    }

    func testAnExitDuringDeleteAndCleanUpStartsNoSecondCleanup() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(fullPlan)])
        let vm = makeVM(runner)
        let row = try await runningRow(finished: true)
        vm.cleaningUpSessions.insert(row.id)

        try await exitAgent(vm, row)

        XCTAssertTrue(runner.calls.isEmpty, "the Delete dialog's own cleanup owns the row")
    }
}
