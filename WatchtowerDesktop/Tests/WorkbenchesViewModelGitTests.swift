import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The workbench header's branch flow (#233) on the AppState-owned view
/// model: every git step is a `workbench git` call, guards come back from Go.
@MainActor
final class WorkbenchesViewModelGitTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var project: Workbench!

    /// Records what the view model asks of the refs watcher.
    final class FakeWatcher: GitRefsWatching {
        let gitDir: String
        let commonDir: String
        let onChange: @MainActor () -> Void
        private(set) var stopped = false

        init(gitDir: String, commonDir: String, onChange: @escaping @MainActor () -> Void) {
            self.gitDir = gitDir
            self.commonDir = commonDir
            self.onChange = onChange
        }

        func stop() { stopped = true }
    }

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelGitTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt git \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = folder.path
        project = try pool.write { d in
            let id = try TestDatabase.insertWorkbench(d, name: "acme", folder: folderPath)
            return try XCTUnwrap(WorkbenchQueries.fetch(d, id: id))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func status(
        branch: String = "main",
        dirty: Bool = false,
        git: Bool = true,
        topLevel: String = "",
        gitDir: String = "/r/.git",
        commonDir: String = "/r/.git"
    ) -> Data {
        Data(#"""
            {"workbench_id":\#(project.id),"git_available":\#(git),"git":\#(git),"branch":"\#(branch)",
             "head":"a1b2c3d","dirty":\#(dirty),"changes":\#(dirty ? 3 : 0),"top_level":"\#(topLevel)",
             "git_dir":"\#(gitDir)","common_dir":"\#(commonDir)","status_ok":true,"status_error":""}
            """#.utf8)
    }

    private func branches(_ names: [String] = ["main", "feature/x"]) -> Data {
        let items = names.map { #"{"name":"\#($0)","current":\#($0 == "main")}"# }
        return Data(#"{"git":true,"current":"main","branches":[\#(items.joined(separator: ","))],"branches_ok":true}"#.utf8)
    }

    private func switchResult(_ fields: String) -> Data {
        Data(#"{"workbench_id":\#(project.id),"branch":"feature/x",\#(fields),"status":{}}"#.utf8)
    }

    private func makeVM(_ runner: any CLIRunnerProtocol, terminals: TerminalCenter? = nil) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults, terminalCenter: terminals)
    }

    private func switchArgs(_ extra: [String]) -> [String] {
        ["workbench", "git", "switch", "--workbench", String(project.id), "--branch", "feature/x"] + extra + ["--json"]
    }

    /// The fake processes `terminalCenter()` started, in start order.
    private var fakeSessions: [FakeTerminalSession] = []

    private func terminalCenter() -> TerminalCenter {
        let center = TerminalCenter { [weak self] in
            let session = FakeTerminalSession()
            self?.fakeSessions.append(session)
            return session
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in false }
        return center
    }

    /// Starts a live `claude` session in `folder` — of the workbench, or a
    /// standalone terminal with `projectID: nil`.
    private func startClaude(in center: TerminalCenter, folder path: String, projectID: Int64?) throws {
        let row = try pool.write { d in
            try TerminalSessionQueries.create(d, .init(
                projectID: projectID, kind: .claude, title: "s", folderPath: path,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        center.start(row, fresh: true)
    }

    /// A TerminalCenter running one live `claude` session in the workbench.
    private func liveClaudeCenter() throws -> TerminalCenter {
        let center = terminalCenter()
        try startClaude(in: center, folder: folder.path, projectID: project.id)
        XCTAssertTrue(center.hasLiveClaudeSession(workbenchID: project.id, workTree: folder.path))
        return center
    }

    // MARK: - Switch guards

    func testProj10_ADirtyRefusalWaitsForTheOwnerWithNoSecondCall() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"],"changes":3"#))
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(runner.invocations, [switchArgs([])], "the first try carries no confirmation flag")
        let pending = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        XCTAssertEqual(pending.primaryLabel, "Stash and switch")
        XCTAssertTrue(pending.stash)
        XCTAssertNil(vm.switchingBranch[project.id])
        XCTAssertNil(vm.gitErrors[project.id])
    }

    func testProj10_ConfirmResendsWithStash() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"],"changes":3"#)),
            .success(switchResult(#""switched":true,"stashed":"37ec889","stash_message":"watchtower: switching from main to feature/x [d0a6]""#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        let pending = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        await vm.confirmPendingSwitch(project: project, confirming: pending)
        XCTAssertEqual(runner.invocations[1], switchArgs(["--stash"]))
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "feature/x")
        XCTAssertEqual(vm.gitStashNotes[project.id]?.text, "Your changes are saved in the stash entry "
                       + "\"watchtower: switching from main to feature/x [d0a6]\" — get them back with git stash apply 37ec889.")
    }

    func testProj10_CancelClearsThePendingSwitchWithNoCall() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"]"#))
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        vm.cancelPendingSwitch(projectID: project.id)
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
        XCTAssertEqual(runner.invocations.count, 1, "cancelling sends nothing")
    }

    /// The dialog's dismissal clears the pending switch; the confirmation it
    /// showed still goes through.
    func testProj10_TheShownConfirmationGoesThroughAfterTheDialogClearedIt() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"]"#)),
            .success(switchResult(#""switched":true"#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        let shown = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        vm.cancelPendingSwitch(projectID: project.id)
        await vm.confirmPendingSwitch(project: project, confirming: shown)
        XCTAssertEqual(runner.invocations[1], switchArgs(["--stash"]))
    }

    func testProj10_ALiveSessionIsReportedAndItsConfirmationResent() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["agent_running"]"#)),
            .success(switchResult(#""switched":true"#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let vm = makeVM(runner, terminals: try liveClaudeCenter())
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(runner.invocations[0], switchArgs(["--agent-running"]))
        let pending = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        XCTAssertTrue(pending.message.contains("the agent's files will be swapped"))
        XCTAssertEqual(pending.primaryLabel, "Switch anyway")
        await vm.confirmPendingSwitch(project: project, confirming: pending)
        XCTAssertEqual(runner.invocations[1], switchArgs(["--agent-running", "--confirm-agent"]))
    }

    /// The owner confirmed the stash; a session started before the resend:
    /// the resend reports it (no `--confirm-agent` — the owner was not
    /// asked), Go asks, and confirming that keeps the stash.
    func testProj10_ASessionStartedAfterAStashConfirmationIsAskedAbout() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"],"changes":3"#)),
            .success(switchResult(#""switched":false,"needs_confirmation":["agent_running"],"changes":3"#)),
            .success(switchResult(#""switched":true"#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let center = terminalCenter()
        let vm = makeVM(runner, terminals: center)
        await vm.switchBranch("feature/x", project: project)
        let stash = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        try startClaude(in: center, folder: folder.path, projectID: project.id)
        await vm.confirmPendingSwitch(project: project, confirming: stash)
        XCTAssertEqual(runner.invocations[1], switchArgs(["--stash", "--agent-running"]))
        let agent = try XCTUnwrap(vm.pendingBranchConfirmation[project.id], "Go's agent question reaches the owner")
        XCTAssertTrue(agent.confirmAgent)
        XCTAssertTrue(agent.stash, "the confirmed stash rides along")
        await vm.confirmPendingSwitch(project: project, confirming: agent)
        XCTAssertEqual(runner.invocations[2], switchArgs(["--stash", "--agent-running", "--confirm-agent"]))
    }

    /// Go asked about a live session; it exited before the owner confirmed:
    /// the resend reports no agent and confirms none.
    func testProj10_ASessionThatExitedBeforeTheConfirmationIsNotReported() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["agent_running"]"#)),
            .success(switchResult(#""switched":true"#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let center = try liveClaudeCenter()
        let vm = makeVM(runner, terminals: center)
        await vm.switchBranch("feature/x", project: project)
        let pending = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        fakeSessions[0].exit(0)
        await vm.confirmPendingSwitch(project: project, confirming: pending)
        XCTAssertEqual(runner.invocations[1], switchArgs([]))
    }

    /// The workbench is a subfolder of its repository; a session at the
    /// repository root works in the files the switch swaps.
    func testProj10_ASessionAtTheRepositoryRootOfASubfolderWorkbenchIsReported() async throws {
        let sub = folder.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let subPath = sub.path
        let workbench = try await pool.write { d in
            let id = try TestDatabase.insertWorkbench(d, name: "app", folder: subPath)
            return try XCTUnwrap(WorkbenchQueries.fetch(d, id: id))
        }
        let runner = ScriptedCLIRunner(results: [
            .success(status(topLevel: folder.path)),
            .success(switchResult(#""switched":false,"needs_confirmation":["agent_running"]"#))
        ])
        let center = terminalCenter()
        try startClaude(in: center, folder: folder.path, projectID: nil)
        let vm = makeVM(runner, terminals: center)
        await vm.refreshGitStatus(projectID: workbench.id)
        await vm.switchBranch("feature/x", project: workbench)
        XCTAssertEqual(runner.invocations[1],
                       ["workbench", "git", "switch", "--workbench", String(workbench.id), "--branch", "feature/x",
                        "--agent-running", "--json"])
    }

    func testAPendingConfirmationOutlivesAReadOfTheSameBranch() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(status(branch: "main")),
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"]"#)),
            .success(status(branch: "main", dirty: true))
        ])
        let vm = makeVM(runner)
        await vm.refreshGitStatus(projectID: project.id)
        await vm.switchBranch("feature/x", project: project)
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNotNil(vm.pendingBranchConfirmation[project.id], "the poll's read changes nothing it asked about")
    }

    /// Asked while on main; the folder moved to another branch (the agent,
    /// a terminal) before the owner answered: the question is stale.
    func testProj10_APendingConfirmationIsDroppedWhenTheBranchMoved() async {
        let runner = ScriptedCLIRunner(results: [
            .success(status(branch: "main")),
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"]"#)),
            .success(status(branch: "hotfix"))
        ])
        let vm = makeVM(runner)
        await vm.refreshGitStatus(projectID: project.id)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertNotNil(vm.pendingBranchConfirmation[project.id])
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
    }

    func testProj10_APendingConfirmationIsDroppedOnceTheFolderIsOnItsBranch() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["agent_running"]"#)),
            .success(status(branch: "feature/x"))
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertNotNil(vm.pendingBranchConfirmation[project.id], "no status was known when Go asked")
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
    }

    func testARefusalShowsGosDetailAndKeepsTheStatus() async {
        let runner = ScriptedCLIRunner(results: [
            .success(status(branch: "main")),
            .success(switchResult(#""switched":false,"refused":"checked_out_elsewhere","refused_detail":"feature/x is open in worktree acme-x""#)),
            .success(status(branch: "main")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.refreshGitStatus(projectID: project.id)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitErrors[project.id], "feature/x is open in worktree acme-x")
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "main")
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
    }

    func testAFailedCallShowsItsErrorAndKeepsTheLastStatus() async {
        let runner = ScriptedCLIRunner(results: [
            .success(status(branch: "main")),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "no such workbench")),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "no such workbench"))
        ])
        let vm = makeVM(runner)
        await vm.refreshGitStatus(projectID: project.id)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitErrors[project.id]?.hasPrefix("Could not switch to feature/x:"), true)
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "main", "the last known status stays")
        XCTAssertNotNil(vm.gitStatusErrors[project.id])
    }

    func testGitStderrShowsAsText() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"error":"error: Your local changes would be overwritten","#
                                  + #""stashed":"2dd96e0","stash_message":"watchtower: m","stash_restored":true"#)),
            .success(status()),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitErrors[project.id], "git failed: error: Your local changes would be overwritten")
        XCTAssertEqual(vm.gitStashNotes[project.id]?.text,
                       "Your changes are back in the work tree; the stash entry \"watchtower: m\" was kept on the stack.")
    }

    func testAStashThatCouldNotBePutBackIsShownAsAnError() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"error":"error: simulated switch failure","stashed":"d28fb3e","#
                                  + #""stash_message":"watchtower: m","stash_error":"error: conflict""#)),
            .success(status()),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitErrors[project.id], "git failed: error: simulated switch failure")
        XCTAssertEqual(vm.gitStashNotes[project.id]?.isError, true)
        XCTAssertEqual(vm.gitStashNotes[project.id]?.text.contains("only in the stash entry \"watchtower: m\""), true)
        XCTAssertEqual(vm.gitStashNotes[project.id]?.text.contains("git stash apply d28fb3e"), true)
        XCTAssertNil(vm.gitNotices[project.id])
    }

    /// The stash note is the only place the app names the stash sha: it
    /// outlives reopening the popover, a status refresh and a switch that
    /// stashed nothing, until the owner dismisses it or a newer stash
    /// replaces it.
    func testTheStashNoteStaysUntilDismissedOrReplaced() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"error":"error: simulated switch failure","stashed":"d28fb3e","#
                                  + #""stash_message":"watchtower: m","stash_error":"error: conflict""#)),
            .success(status()),
            .success(branches()),
            // The popover reopens, the status refreshes.
            .success(branches()),
            .success(status()),
            // A switch that stashed nothing.
            .success(switchResult(#""switched":true"#)),
            .success(status(branch: "feature/x")),
            .success(branches()),
            // A newer stash.
            .success(switchResult(#""switched":true,"stashed":"37ec889","stash_message":"watchtower: n""#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        let first = try XCTUnwrap(vm.gitStashNotes[project.id])
        XCTAssertTrue(first.text.contains("git stash apply d28fb3e"))

        await vm.loadBranches(project: project)
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNil(vm.gitErrors[project.id], "a transient error still clears on reopen")
        XCTAssertEqual(vm.gitStashNotes[project.id], first, "the stash note survives reopen and refresh")

        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitStashNotes[project.id], first, "a switch without a stash leaves it")

        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitStashNotes[project.id]?.entry, "watchtower: n", "a newer stash replaces it")
        XCTAssertEqual(vm.gitStashNotes[project.id]?.isError, false)

        vm.dismissStashNote(projectID: project.id)
        XCTAssertNil(vm.gitStashNotes[project.id])
    }

    func testAWarningAfterASwitchIsANotice() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":true,"warning":"hook says no""#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertNil(vm.gitErrors[project.id])
        XCTAssertEqual(vm.gitNotices[project.id], "Switched to feature/x, but git reported: hook says no")
    }

    func testAWarningAfterACreateIsANotice() async {
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"branch":"topic","switched":true,"created":true,"warning":"hook says no"}"#.utf8)),
            .success(status(branch: "topic")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        let created = await vm.createBranch("topic", project: project)
        XCTAssertTrue(created)
        XCTAssertNil(vm.gitErrors[project.id])
        XCTAssertEqual(vm.gitNotices[project.id], "Created topic, but git reported: hook says no")
    }

    func testASuccessfulSwitchReadsTheStatusAndTheBranchesAgain() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":true"#)),
            .success(status(branch: "feature/x")),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        let id = String(project.id)
        XCTAssertEqual(runner.invocations, [
            switchArgs([]),
            ["workbench", "git", "status", "--workbench", id, "--json"],
            ["workbench", "git", "branches", "--workbench", id, "--json"]
        ])
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "feature/x")
        XCTAssertEqual(vm.gitBranches[project.id]?.branches.map(\.name), ["main", "feature/x"])
        XCTAssertNil(vm.gitErrors[project.id])
        XCTAssertNil(vm.gitNotices[project.id], "no stash, no note")
    }

    // MARK: - Status, branches, create, copy

    private func unreadableStatus(_ error: String = "fatal: this operation must be run in a work tree") -> Data {
        Data(#"{"workbench_id":\#(project.id),"git_available":true,"git":true,"status_ok":false,"status_error":"\#(error)"}"#.utf8)
    }

    func testAnUnreadableStatusKeepsTheLastGoodOneAndSaysWhy() async {
        let runner = ScriptedCLIRunner(results: [.success(status(branch: "main")), .success(unreadableStatus()), .success(status())])
        let vm = makeVM(runner)
        await vm.refreshGitStatus(projectID: project.id)
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "main", "the button does not vanish")
        XCTAssertEqual(vm.gitStatus[project.id]?.statusOK, true)
        XCTAssertEqual(vm.gitStatusErrors[project.id],
                       "Could not read the git status: fatal: this operation must be run in a work tree")
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNil(vm.gitStatusErrors[project.id], "a good read clears it")
    }

    func testAFirstUnreadableStatusLeavesNoStatusButAnError() async {
        let vm = makeVM(ScriptedCLIRunner(results: [.success(unreadableStatus())]))
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNil(vm.gitStatus[project.id])
        XCTAssertNotNil(vm.gitStatusErrors[project.id])
    }

    func testAMissingCLIIsAStatusError() async {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertEqual(vm.gitStatusErrors[project.id], WorkbenchesViewModel.cliMissingMessage)
    }

    func testAnUndecodableStatusSaysTheCLIIsOutOfStep() async {
        let vm = makeVM(ScriptedCLIRunner(results: [.success(Data(#"{"branch":"main"}"#.utf8))]))
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertEqual(vm.gitStatusErrors[project.id], "Could not read the git status: unexpected output from "
                       + "`watchtower workbench git status` — the CLI and the app may be out of sync; update Watchtower")
    }

    func testProj10_NoGitHidesTheButton() async {
        let vm = makeVM(ScriptedCLIRunner(results: [.success(status(git: false))]))
        XCTAssertFalse(WorkbenchBranchPresentation.showsButton(vm.gitStatus[project.id]), "unknown status: no button")
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertFalse(WorkbenchBranchPresentation.showsButton(vm.gitStatus[project.id]))
        XCTAssertNil(vm.gitStatusErrors[project.id], "not a work tree is no error")
        let withGit = makeVM(ScriptedCLIRunner(results: [.success(status())]))
        await withGit.refreshGitStatus(projectID: project.id)
        XCTAssertTrue(WorkbenchBranchPresentation.showsButton(withGit.gitStatus[project.id]))
    }

    /// Requests while a read runs queue exactly one rerun: two calls, not
    /// one (the queued rerun is never dropped) and not five.
    func testConcurrentRefreshesCoalesceToTwoCalls() async {
        let held = HeldCLIRunner(stdout: status())
        let vm = makeVM(held)
        let first = Task { await vm.refreshGitStatus(projectID: project.id) }
        await awaitStarted(held)
        for _ in 0..<4 { await vm.refreshGitStatus(projectID: project.id) }
        held.release()
        await first.value
        XCTAssertEqual(held.invocations.count, 2)
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "main")
    }

    func testARefreshAloneIsOneCall() async {
        let runner = ScriptedCLIRunner(results: [.success(status())])
        let vm = makeVM(runner)
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// The loop's owner was cancelled (the page went away) while another
    /// caller queued a rerun: the rerun still happens.
    func testACancelledOwnerHandsTheQueuedRerunOn() async {
        let runner = CancellableFirstCallRunner(stdout: status(branch: "feature/x"))
        let vm = makeVM(runner)
        let owner = Task { await vm.refreshGitStatus(projectID: project.id) }
        await runner.started.wait()
        await vm.refreshGitStatus(projectID: project.id)
        owner.cancel()
        runner.release()
        await owner.value
        await waitUntil { runner.invocations.count == 2 && vm.gitStatus[self.project.id] != nil }
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "feature/x")
        XCTAssertTrue(vm.gitRefreshing.isEmpty)
    }

    func testACancelledOwnerWithNothingQueuedStops() async {
        let runner = CancellableFirstCallRunner(stdout: status())
        let vm = makeVM(runner)
        let owner = Task { await vm.refreshGitStatus(projectID: project.id) }
        await runner.started.wait()
        owner.cancel()
        runner.release()
        await owner.value
        await settle(vm)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(vm.gitStatus[project.id])
        XCTAssertNil(vm.gitStatusErrors[project.id], "a cancelled read reports nothing")
    }

    func testLoadBranchesReadsTheBoardBadges() async throws {
        let projectID = project.id
        try await pool.write { d in
            let id = try TestDatabase.insertWorkbenchTarget(d, projectID: projectID, text: "Login")
            try d.execute(sql: "UPDATE targets SET branch = 'feature/x' WHERE id = ?", arguments: [id])
        }
        let vm = makeVM(ScriptedCLIRunner(results: [.success(branches())]))
        vm.gitErrors[projectID] = "old"
        await vm.loadBranches(project: project)
        XCTAssertNil(vm.gitErrors[projectID], "opening the popover clears the last message")
        XCTAssertEqual(vm.branchTargets[projectID]?["feature/x"]?.map(\.title), ["Login"])
        XCTAssertEqual(vm.gitBranches[projectID]?.branches.count, 2)
    }

    func testAFailedListingIsAFailedState() async {
        let vm = makeVM(ScriptedCLIRunner(results: [
            .success(Data(#"{"git":true,"branches":[],"branches_ok":false,"branches_error":"fatal: bad object"}"#.utf8))
        ]))
        await vm.loadBranches(project: project)
        XCTAssertEqual(vm.branchListStates[project.id], .failed("Could not list branches: fatal: bad object"))
        XCTAssertNil(vm.gitBranches[project.id], "no list, so no endless spinner either: the state says failed")
        XCTAssertNil(vm.gitErrors[project.id], "the list's failure is the list's, not the last action's")
    }

    func testAListingOfANonRepositoryShowsTheNote() async {
        let vm = makeVM(ScriptedCLIRunner(results: [
            .success(Data(#"{"git":false,"note":"the folder is not a git work tree","branches":[],"branches_ok":false,"branches_error":""}"#.utf8))
        ]))
        await vm.loadBranches(project: project)
        XCTAssertEqual(vm.branchListStates[project.id], .failed("Could not list branches: the folder is not a git work tree"))
    }

    func testAFailedReloadKeepsTheOldListAsStale() async {
        let runner = ScriptedCLIRunner(results: [
            .success(branches()),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "no such workbench"))
        ])
        let vm = makeVM(runner)
        await vm.loadBranches(project: project)
        XCTAssertEqual(vm.branchListStates[project.id], .loaded)
        await vm.loadBranches(project: project)
        XCTAssertEqual(vm.gitBranches[project.id]?.branches.map(\.name), ["main", "feature/x"])
        guard case .failed(let message) = vm.branchListStates[project.id] else {
            return XCTFail("expected a failed state, got \(String(describing: vm.branchListStates[project.id]))")
        }
        XCTAssertTrue(message.hasPrefix("Could not list branches: "), message)
    }

    func testAMissingCLIFailsTheList() async {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.loadBranches(project: project)
        XCTAssertEqual(vm.branchListStates[project.id], .failed(WorkbenchesViewModel.cliMissingMessage))
    }

    func testAFailedBadgeReadDropsTheOldBadges() async throws {
        let vm = makeVM(ScriptedCLIRunner(results: [.success(branches())]))
        vm.branchTargets[project.id] = ["feature/x": [WorkbenchBranchTarget(id: 1, title: "old", status: "todo")]]
        try await pool.write { try $0.execute(sql: "ALTER TABLE targets RENAME TO targets_gone") }
        await vm.loadBranches(project: project)
        XCTAssertNil(vm.branchTargets[project.id], "stale badges are not shown as current")
        XCTAssertEqual(vm.gitErrors[project.id]?.hasPrefix("Could not read the board's branches:"), true)
        XCTAssertEqual(vm.branchListStates[project.id], .loaded)
    }

    func testAFailedCreateCallReadsTheStatusAgain() async {
        let runner = ScriptedCLIRunner(results: [
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "killed")),
            .success(status(branch: "new/one"))
        ])
        let vm = makeVM(runner)
        let created = await vm.createBranch("new/one", project: project)
        XCTAssertFalse(created)
        XCTAssertEqual(runner.invocations.last, ["workbench", "git", "status", "--workbench", String(project.id), "--json"])
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "new/one", "git may have written before the call failed")
        XCTAssertEqual(vm.gitErrors[project.id]?.hasPrefix("Could not create new/one:"), true)
    }

    func testASwitchThatReportsNothingSaysItDidNotHappen() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false"#)),
            .success(status()),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(vm.gitErrors[project.id], "Not switched to feature/x.")
    }

    func testAlreadyOnTheBranchIsNoError() async {
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"already":true"#)),
            .success(status()),
            .success(branches())
        ])
        let vm = makeVM(runner)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertNil(vm.gitErrors[project.id])
    }

    func testCreateRefusedAndEmptyName() async {
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"branch":"main","switched":false,"created":false,"refused":"exists"}"#.utf8)),
            .success(status()),
            .success(branches())
        ])
        let vm = makeVM(runner)
        let empty = await vm.createBranch("   ", project: project)
        XCTAssertFalse(empty)
        XCTAssertTrue(runner.invocations.isEmpty, "an empty name never reaches the CLI")
        XCTAssertEqual(vm.gitErrors[project.id], "Enter a name for the new branch.")
        let exists = await vm.createBranch("main", project: project)
        XCTAssertFalse(exists)
        XCTAssertEqual(vm.gitErrors[project.id], "A branch with that name already exists.")
    }

    func testCopyBranchNameCopiesTheBranchOrTheHash() async {
        let vm = makeVM(ScriptedCLIRunner(results: [.success(status(branch: "feature/x"))]))
        var copied: [String] = []
        vm.copyToPasteboard = { copied.append($0) }
        vm.copyBranchName(projectID: project.id)
        XCTAssertEqual(copied, [], "nothing known yet")
        await vm.refreshGitStatus(projectID: project.id)
        vm.copyBranchName(projectID: project.id)
        vm.gitStatus[project.id]?.detached = true
        vm.copyBranchName(projectID: project.id)
        XCTAssertEqual(copied, ["feature/x", "a1b2c3d"])
    }

    // MARK: - Navigation and watching

    /// House rule: a switch started, the owner left the page and came back —
    /// it is still running, then its result lands on its own workbench.
    func testASwitchInFlightSurvivesNavigation() async {
        let held = HeldCLIRunner(stdout: switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"]"#))
        let vm = makeVM(held)
        vm.selectedWorkbenchID = project.id
        let run = Task { await vm.switchBranch("feature/x", project: project) }
        await awaitStarted(held)
        vm.stopGitWatching(projectID: project.id)
        vm.selectedWorkbenchID = 999
        vm.selectedWorkbenchID = project.id
        XCTAssertEqual(vm.switchingBranch[project.id], "feature/x")
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(held.invocations.count, 1, "a second click while one runs starts nothing")
        held.release()
        await run.value
        XCTAssertNil(vm.switchingBranch[project.id])
        XCTAssertNotNil(vm.pendingBranchConfirmation[project.id])
    }

    func testWatchingArmsTheWatcherAndStopCancelsEverything() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(status(gitDir: "/r/.git/worktrees/w", commonDir: "/r/.git")),
            .success(status(gitDir: "/r2/.git", commonDir: "/r2/.git"))
        ])
        let vm = makeVM(runner)
        var watchers: [FakeWatcher] = []
        vm.makeGitWatcher = { gitDir, commonDir, onChange in
            let watcher = FakeWatcher(gitDir: gitDir, commonDir: commonDir, onChange: onChange)
            watchers.append(watcher)
            return watcher
        }
        var sleeps = 0
        vm.gitPollSleep = { _ in
            sleeps += 1
            try? await Task.sleep(for: .seconds(3600))
        }
        await vm.startGitWatching(project: project)
        XCTAssertEqual(watchers.count, 1)
        XCTAssertEqual(watchers.first?.gitDir, "/r/.git/worktrees/w")
        XCTAssertEqual(watchers.first?.commonDir, "/r/.git")

        // A ref change re-reads the status; new dirs re-arm the watcher.
        watchers[0].onChange()
        await waitUntil { runner.invocations.count == 2 && watchers.count == 2 }
        XCTAssertTrue(watchers[0].stopped)
        XCTAssertEqual(watchers[1].gitDir, "/r2/.git")
        XCTAssertNotNil(vm.gitTimers[project.id])

        vm.stopGitWatching(projectID: project.id)
        XCTAssertTrue(watchers[1].stopped)
        XCTAssertNil(vm.gitTimers[project.id])
        XCTAssertTrue(vm.gitWatchers.isEmpty)
        XCTAssertNil(vm.gitActivationObserver)
        XCTAssertEqual(vm.gitStatus[project.id]?.gitDir, "/r2/.git", "the status stays")
        XCTAssertLessThanOrEqual(sleeps, 1)
    }

    func testThePollRefreshesOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedCLIRunner(results: [.success(status(gitDir: ""))])
        let vm = makeVM(runner)
        var onScreen = false
        vm.isTabOnScreen = { onScreen }
        let ticks = AsyncStream<Void>.makeStream()
        var tickIterator = ticks.stream.makeAsyncIterator()
        vm.gitPollSleep = { _ in _ = await tickIterator.next() }
        await vm.startGitWatching(project: project)
        XCTAssertEqual(runner.invocations.count, 1)
        ticks.continuation.yield()
        await settle(vm)
        XCTAssertEqual(runner.invocations.count, 1, "off screen: no read")
        onScreen = true
        ticks.continuation.yield()
        await waitUntil { runner.invocations.count == 2 }
        vm.stopGitWatching(projectID: project.id)
        ticks.continuation.finish()
    }

    func testAppActivationRefreshesWatchedWorkbenches() async {
        let runner = ScriptedCLIRunner(results: [.success(status(gitDir: ""))])
        let vm = makeVM(runner)
        let center = NotificationCenter()
        vm.gitNotificationCenter = center
        vm.gitPollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        await vm.startGitWatching(project: project)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { runner.invocations.count == 2 }
        vm.stopGitWatching(projectID: project.id)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle(vm)
        XCTAssertEqual(runner.invocations.count, 2, "not watched any more")
    }

    // MARK: - Helpers

    /// The first call waits for `release()` and then fails as a cancelled
    /// process does; every later call answers at once.
    final class CancellableFirstCallRunner: CLIRunnerProtocol, @unchecked Sendable {
        let started = AsyncGate()
        private let finish = AsyncGate()
        private let stdout: Data
        private let lock = NSLock()
        private var recorded: [[String]] = []

        init(stdout: Data) { self.stdout = stdout }

        var invocations: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func release() { finish.release() }

        func run(args: [String]) async throws -> Data {
            lock.lock()
            recorded.append(args)
            let first = recorded.count == 1
            lock.unlock()
            guard first else { return stdout }
            started.release()
            await finish.wait()
            try Task.checkCancellation()
            return stdout
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets queued main-actor tasks run.
    private func settle(_ vm: WorkbenchesViewModel) async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }
}
