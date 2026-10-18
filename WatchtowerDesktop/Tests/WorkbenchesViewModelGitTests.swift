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
        let onChange: @MainActor (GitRefsChange) -> Void
        private(set) var stopped = false

        init(gitDir: String, commonDir: String, onChange: @escaping @MainActor (GitRefsChange) -> Void) {
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
        XCTAssertTrue(center.hasLiveAgentSession(workbenchID: project.id, workTree: folder.path))
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
        vm.cancelPendingSwitch(key: .mainFolder(project.id))
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
        vm.cancelPendingSwitch(key: .mainFolder(project.id))
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

    // MARK: - The code viewer's edits

    private func writeFile(_ name: String, _ text: String, in dir: URL? = nil) throws {
        try text.write(to: (dir ?? folder).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func readFile(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// An edit the page has not sent yet (its debounce) and one waiting for
    /// its autosave are both on disk when Go is asked about a dirty tree.
    func testProj10_ASwitchFirstSavesTheCodeViewersEdits() async throws {
        try writeFile("a.go", "package a\n")
        try writeFile("b.go", "package b\n")
        let fileA = folder.appendingPathComponent("a.go")
        let fileB = folder.appendingPathComponent("b.go")
        let runner = DiskPeekingRunner(files: [fileA, fileB], results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"],"changes":2"#))
        ])
        let vm = makeVM(runner)
        let bufferA = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "a.go")
        bufferA.loadIfNeeded()
        let bufferB = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "b.go")
        bufferB.loadIfNeeded()
        vm.codeFiles.edited(bufferB, text: "package b // typed\n", base: 0)
        let page = EditorPage(edits: [CodeEditorPendingEdit(id: bufferA.id, text: "package a // typed\n", base: 0)])
        vm.codeFiles.register(page, for: project.mainCodeRoot)

        await vm.switchBranch("feature/x", project: project)

        XCTAssertEqual(runner.invocations, [switchArgs([])])
        XCTAssertEqual(runner.seen.first, ["package a // typed\n", "package b // typed\n"],
                       "both edits were on disk when the switch was asked")
        XCTAssertNotNil(vm.pendingBranchConfirmation[project.id])
        XCTAssertNil(vm.gitErrors[project.id])
    }

    /// A buffer holding edits it cannot write (here a conflict with the
    /// disk) holds the switch in the Desktop: nothing reaches Go.
    func testProj10_AnEditThatCannotBeSavedHoldsTheSwitch() async throws {
        try writeFile("a.go", "package a\n")
        let runner = ScriptedCLIRunner(results: [.success(switchResult(#""switched":true"#))])
        let vm = makeVM(runner)
        let buffer = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "a.go")
        buffer.loadIfNeeded()
        vm.codeFiles.edited(buffer, text: "package a // mine\n", base: 0)
        try writeFile("a.go", "package a // theirs\n")
        buffer.diskChanged()
        XCTAssertTrue(buffer.conflict)

        await vm.switchBranch("feature/x", project: project)

        XCTAssertEqual(runner.invocations, [], "no CLI call")
        XCTAssertEqual(vm.gitErrors[project.id], "Save or discard the edits in a.go first — they are not on disk yet.")
        XCTAssertNil(vm.switchingBranch[project.id])
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
        XCTAssertEqual(try readFile("a.go"), "package a // theirs\n", "the disk is not written over")
        XCTAssertTrue(buffer.isDirty, "the edits stay in the buffer")
    }

    /// A page that fails to hand over its edits holds the switch: the files
    /// would be swapped under edits only the page has.
    func testProj10_AnEditorThatDoesNotAnswerHoldsTheSwitch() async throws {
        try writeFile("a.go", "package a\n")
        let runner = ScriptedCLIRunner(results: [.success(switchResult(#""switched":true"#))])
        let vm = makeVM(runner)
        vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "a.go").loadIfNeeded()
        let page = EditorPage(edits: [])
        page.fails = true
        vm.codeFiles.register(page, for: project.mainCodeRoot)

        await vm.switchBranch("feature/x", project: project)

        XCTAssertEqual(runner.invocations, [], "no CLI call")
        XCTAssertEqual(vm.gitErrors[project.id], "The editor did not hand over its latest edits — try again.")
        XCTAssertNil(vm.switchingBranch[project.id])
    }

    /// A page that does not answer in time holds the switch too; the edits
    /// it hands over later still reach their buffer.
    func testProj10_AnEditorThatTimesOutHoldsTheSwitch() async throws {
        try writeFile("a.go", "package a\n")
        let runner = ScriptedCLIRunner(results: [.success(switchResult(#""switched":true"#))])
        let vm = makeVM(runner)
        vm.codeFiles.pendingTimeout = .milliseconds(50)
        let buffer = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "a.go")
        buffer.loadIfNeeded()
        let page = StalledEditorPage()
        vm.codeFiles.register(page, for: project.mainCodeRoot)

        await vm.switchBranch("feature/x", project: project)

        XCTAssertEqual(runner.invocations, [], "no CLI call")
        XCTAssertEqual(vm.gitErrors[project.id], "The editor did not hand over its latest edits — try again.")
        XCTAssertNil(vm.switchingBranch[project.id])
        page.answer([CodeEditorPendingEdit(id: buffer.id, text: "package a // late\n", base: 0)])
        await waitUntil { buffer.text == "package a // late\n" }
        buffer.cancelAutosave()
    }

    /// Open, unedited files — and another workbench's unsaved edit outside
    /// this work tree — leave the switch as it was.
    func testProj10_NoUnsavedEditsInTheWorkTreeLeaveTheSwitchAsItWas() async throws {
        try writeFile("a.go", "package a\n")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("wt other \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try writeFile("c.go", "package c\n", in: other)
        let otherPath = other.path
        let otherProject = try await pool.write { d in
            let id = try TestDatabase.insertWorkbench(d, name: "other", folder: otherPath)
            return try XCTUnwrap(WorkbenchQueries.fetch(d, id: id))
        }
        let runner = ScriptedCLIRunner(results: [
            .success(switchResult(#""switched":false,"needs_confirmation":["uncommitted_changes"],"changes":3"#))
        ])
        let vm = makeVM(runner)
        vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "a.go").loadIfNeeded()
        let foreign = vm.codeFiles.buffer(for: otherProject.mainCodeRoot, relPath: "c.go")
        foreign.loadIfNeeded()
        vm.codeFiles.edited(foreign, text: "package c // mine\n", base: 0)
        try writeFile("c.go", "package c // theirs\n", in: other)
        foreign.diskChanged()
        XCTAssertTrue(foreign.conflict)

        await vm.switchBranch("feature/x", project: project)

        XCTAssertEqual(runner.invocations, [switchArgs([])])
        XCTAssertEqual(vm.pendingBranchConfirmation[project.id]?.primaryLabel, "Stash and switch")
        XCTAssertNil(vm.gitErrors[project.id])
        XCTAssertEqual(try readFile("a.go"), "package a\n")
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
    func testProj10_TheStashNoteStaysUntilDismissedOrReplaced() async throws {
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

        vm.dismissStashNote(key: .mainFolder(project.id))
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
        vm.copyBranchName(key: .mainFolder(project.id))
        XCTAssertEqual(copied, [], "nothing known yet")
        await vm.refreshGitStatus(projectID: project.id)
        vm.copyBranchName(key: .mainFolder(project.id))
        vm.gitStatus[project.id]?.detached = true
        vm.copyBranchName(key: .mainFolder(project.id))
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
        watchers[0].onChange(GitRefsChange(mayMoveWorktrees: true))
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

    /// A setup re-run replaces the view model (board #593): `stop` ends the
    /// title poll, every page's git poll, refs watcher and activation
    /// observer, and the code viewer's folder streams at once.
    func testStopEndsTheTitlePollGitWatchingAndFolderStreams() async throws {
        let runner = ScriptedCLIRunner(results: [.success(status())])
        let vm = makeVM(runner)
        var watchers: [FakeWatcher] = []
        vm.makeGitWatcher = { gitDir, commonDir, onChange in
            let watcher = FakeWatcher(gitDir: gitDir, commonDir: commonDir, onChange: onChange)
            watchers.append(watcher)
            return watcher
        }
        vm.gitPollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        vm.titleSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        vm.startTitleRefresh()
        await vm.startGitWatching(project: project)
        vm.codeFiles.startWatching(CodeRoot(main: project))
        let titleTask = try XCTUnwrap(vm.titleTask)
        XCTAssertEqual(watchers.count, 1)
        XCTAssertNotNil(vm.gitTimers[project.id])
        XCTAssertNotNil(vm.gitActivationObserver)
        XCTAssertFalse(vm.codeFiles.watchers.isEmpty, "the main folder is watched")

        vm.stop()

        XCTAssertTrue(titleTask.isCancelled)
        XCTAssertNil(vm.titleTask)
        XCTAssertTrue(vm.gitWatching.isEmpty)
        XCTAssertTrue(vm.gitTimers.isEmpty)
        XCTAssertTrue(watchers[0].stopped)
        XCTAssertTrue(vm.gitWatchers.isEmpty)
        XCTAssertNil(vm.gitActivationObserver)
        XCTAssertTrue(vm.codeFiles.watchers.isEmpty, "no FSEvents stream left")
    }

    /// A page's watching in flight across `stop()` (its status read held)
    /// arms nothing once it resumes, and a stopped view model never starts
    /// watching again (board #593).
    func testAStoppedViewModelNeverArmsAWatcher() async throws {
        let held = HeldCLIRunner(stdout: status())
        let vm = makeVM(held)
        var watchers: [FakeWatcher] = []
        vm.makeGitWatcher = { gitDir, commonDir, onChange in
            let watcher = FakeWatcher(gitDir: gitDir, commonDir: commonDir, onChange: onChange)
            watchers.append(watcher)
            return watcher
        }
        vm.gitPollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let watching = Task { await vm.startGitWatching(project: self.project) }
        await awaitStarted(held)

        vm.stop()
        held.release()
        await watching.value
        await vm.startGitWatching(project: project)

        XCTAssertTrue(watchers.isEmpty, "no refs watcher after the stop")
        XCTAssertTrue(vm.gitWatchers.isEmpty)
        XCTAssertTrue(vm.gitTimers.isEmpty)
        XCTAssertNil(vm.gitActivationObserver)
        XCTAssertTrue(vm.gitWatching.isEmpty)
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
            let first = lock.withLock {
                recorded.append(args)
                return recorded.count == 1
            }
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

@MainActor
private final class EditorPage: CodeEditorBridge {
    var edits: [CodeEditorPendingEdit]
    /// The page could not be asked (`takePending` answers nil).
    var fails = false
    /// How often the center asked for the unsent edits.
    private(set) var asked = 0

    init(edits: [CodeEditorPendingEdit]) {
        self.edits = edits
    }

    func takePending() async -> [CodeEditorPendingEdit]? {
        asked += 1
        guard !fails else { return nil }
        defer { edits = [] }
        return edits
    }
}

/// A page whose `takePending` answers only when the test says so.
@MainActor
private final class StalledEditorPage: CodeEditorBridge {
    private var waiting: CheckedContinuation<[CodeEditorPendingEdit]?, Never>?

    func takePending() async -> [CodeEditorPendingEdit]? {
        await withCheckedContinuation { waiting = $0 }
    }

    func answer(_ edits: [CodeEditorPendingEdit]) {
        waiting?.resume(returning: edits)
        waiting = nil
    }
}

/// A scripted runner that reads `files` off the disk as each call starts:
/// what Go's dirty check would see.
private final class DiskPeekingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let files: [URL]
    private let scripted: ScriptedCLIRunner
    private let lock = NSLock()
    private var peeks: [[String]] = []

    init(files: [URL], results: [Result<Data, Error>]) {
        self.files = files
        scripted = ScriptedCLIRunner(results: results)
    }

    var invocations: [[String]] { scripted.invocations }

    var seen: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return peeks
    }

    func run(args: [String]) async throws -> Data {
        let contents = files.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        lock.withLock { peeks.append(contents) }
        return try await scripted.run(args: args)
    }
}

// MARK: - The branch menu on the session's worktree (board #565)

extension WorkbenchesViewModelGitTests {
    /// A worktree of the workbench's repository, inside its folder as
    /// Claude Code makes them.
    private func makeWorktree(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(".claude/worktrees/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `claude` row of the workbench whose agent reported `cwd` (nil: no
    /// cwd, an unknown place) after its run started, so a live row trusts it.
    private func agentRow(cwd: String?) async throws -> TerminalSession {
        let projectID = project.id
        let folderPath = folder.path
        return try await pool.write { db in
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "s", folderPath: folderPath,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = ?,
                           agent_turns = '{"since":"2026-10-12T09:00:00.000Z"}' WHERE id = ?
                    """,
                arguments: [cwd, cwd == nil ? nil : "2026-10-12T10:00:00.000Z", row.id]
            )
            return row
        }
    }

    private func worktreeVM(_ runner: WorktreeRunner, terminals: TerminalCenter? = nil) -> WorkbenchesViewModel {
        let vm = makeVM(runner, terminals: terminals)
        vm.makeGitWatcher = { gitDir, commonDir, onChange in
            FakeWatcher(gitDir: gitDir, commonDir: commonDir, onChange: onChange)
        }
        vm.gitPollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        vm.gitNotificationCenter = NotificationCenter()
        return vm
    }

    private func pageShowing(_ sessionID: Int64, in vm: WorkbenchesViewModel) {
        var layout = WorkspaceLayout.default
        layout.primary = .session(sessionID)
        vm.setLayout(layout, projectID: project.id)
    }

    /// The page watches the workbench and shows `sessionID`, placed in its
    /// worktree; the branch menu follows that root (the page's onChange).
    private func showWorktreeSession(_ sessionID: Int64, in vm: WorkbenchesViewModel) async -> CodeRoot {
        await vm.startGitWatching(project: project)
        pageShowing(sessionID, in: vm)
        await waitUntil { !vm.activeCodeRoot(project: self.project).isMain }
        let root = vm.activeCodeRoot(project: project)
        await vm.followGitRoot(root)
        return root
    }

    func testProj10_TheBranchMenuFollowsTheSessionsWorktree() async throws {
        let worktree = try makeWorktree("mobile-a")
        let inWorktree = try await agentRow(cwd: worktree.path)
        let inMain = try await agentRow(cwd: folder.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let vm = worktreeVM(runner)

        let root = await showWorktreeSession(inWorktree.id, in: vm)
        XCTAssertEqual(root, CodeRoot(workbenchID: project.id, worktree: worktree))
        await vm.loadBranches(project: project)
        await vm.switchBranch("feature/x", project: project)
        await vm.createBranch("topic", project: project)
        for command in ["status", "branches", "switch", "create"] {
            XCTAssertEqual(runner.folders(command).last, worktree.path, "\(command) runs in the session's worktree")
        }
        XCTAssertEqual(vm.gitStatus[root]?.branch, "feature/wt", "the header shows the worktree's branch")
        XCTAssertEqual(vm.gitStatus[project.id]?.branch, "main", "the main folder's entry is its own")

        for pane in [WorkspacePane.board, .session(inMain.id)] {
            runner.clearRecorded()
            var layout = WorkspaceLayout.default
            layout.primary = pane
            vm.setLayout(layout, projectID: project.id)
            XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot)
            await vm.followGitRoot(project.mainCodeRoot)
            await vm.loadBranches(project: project)
            await vm.switchBranch("feature/x", project: project)
            for command in ["branches", "switch"] {
                let folders = runner.folders(command)
                XCTAssertFalse(folders.isEmpty, "\(pane): \(command) ran")
                XCTAssertTrue(folders.allSatisfy { $0 == nil }, "\(pane): no --folder for the main folder's \(command)")
            }
        }
        vm.stopGitWatching(projectID: project.id)
    }

    /// A live session proven in worktree B does not count for a switch in
    /// worktree A; one whose place is unknown (no cwd yet) does, and so does
    /// one in A itself.
    func testProj10_ASessionInAnotherWorktreeIsNotReportedAnUnknownOneIs() async throws {
        let worktreeA = try makeWorktree("mobile-a")
        let worktreeB = try makeWorktree("mobile-b")
        let shown = try await agentRow(cwd: worktreeA.path)
        let elsewhere = try await agentRow(cwd: worktreeB.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let center = terminalCenter()
        center.start(elsewhere, fresh: true)
        let vm = worktreeVM(runner, terminals: center)
        _ = await showWorktreeSession(shown.id, in: vm)
        await waitUntil {
            if case .worktree = vm.sessionPlaces.currentPlace(sessionID: elsewhere.id) { return true }
            return false
        }

        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(runner.switches.last?.contains("--agent-running"), false,
                       "a session working in worktree B is not in A")

        let unknown = try await agentRow(cwd: nil)
        center.start(unknown, fresh: true)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(runner.switches.last?.contains("--agent-running"), true, "an unknown place may be A")
        XCTAssertEqual(runner.switches.count, 2)
        vm.stopGitWatching(projectID: project.id)
    }

    /// A switch in worktree A saves A's edits and never the main folder's;
    /// an edit in A that cannot be saved holds it.
    func testProj10_ASwitchInAWorktreeSavesThatWorktreesEdits() async throws {
        let worktree = try makeWorktree("mobile-a")
        try writeFile("a.go", "package a\n", in: worktree)
        try writeFile("m.go", "package m\n")
        let shown = try await agentRow(cwd: worktree.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let vm = worktreeVM(runner)
        let root = await showWorktreeSession(shown.id, in: vm)
        let inMain = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "m.go")
        inMain.loadIfNeeded()
        vm.codeFiles.edited(inMain, text: "package m // main's\n", base: 0)
        let inA = vm.codeFiles.buffer(for: root, relPath: "a.go")
        inA.loadIfNeeded()
        vm.codeFiles.edited(inA, text: "package a // A's\n", base: 0)

        await vm.switchBranch("feature/x", project: project)

        XCTAssertEqual(runner.switches.count, 1)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("a.go"), encoding: .utf8),
                       "package a // A's\n", "A's edit is on disk before Go's dirty check")
        XCTAssertEqual(try readFile("m.go"), "package m\n", "the main folder's edit is not this switch's")
        XCTAssertTrue(inMain.isDirty)

        vm.codeFiles.edited(inA, text: "package a // mine\n", base: 0)
        try writeFile("a.go", "package a // theirs\n", in: worktree)
        inA.diskChanged()
        XCTAssertTrue(inA.conflict)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(runner.switches.count, 1, "no CLI call")
        XCTAssertEqual(vm.gitErrors[root], "Save or discard the edits in a.go first — they are not on disk yet.")
        XCTAssertNil(vm.gitErrors[project.id], "the main folder's menu is not touched")
        vm.stopGitWatching(projectID: project.id)
    }

    /// A place whose re-read failed is stale: maybe in the worktree being
    /// switched, so the agent question is asked again.
    func testAStalePlaceCountsAsMaybeHere() async throws {
        let worktreeA = try makeWorktree("mobile-a")
        let worktreeB = try makeWorktree("mobile-b")
        let shown = try await agentRow(cwd: worktreeA.path)
        let elsewhere = try await agentRow(cwd: worktreeB.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let center = terminalCenter()
        center.start(elsewhere, fresh: true)
        let vm = worktreeVM(runner, terminals: center)
        _ = await showWorktreeSession(shown.id, in: vm)
        await waitUntil {
            if case .worktree = vm.agentPlace(sessionID: elsewhere.id) { return true }
            return false
        }

        runner.failFolderReads()
        vm.sessionPlaces.refreshPlaces(workbenchID: project.id)
        await waitUntil { vm.sessionPlaces.isPlaceStale(sessionID: elsewhere.id) }
        XCTAssertEqual(vm.agentPlace(sessionID: elsewhere.id), .unknown)
        await vm.switchBranch("feature/x", project: project)
        XCTAssertEqual(runner.switches.last?.contains("--agent-running"), true)
        vm.stopGitWatching(projectID: project.id)
    }

    /// Go's refusals of a session's folder reach the popover in words.
    func testAFolderRefusalOfTheBranchListIsShown() async throws {
        let worktree = try makeWorktree("mobile-a")
        let shown = try await agentRow(cwd: worktree.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let vm = worktreeVM(runner)
        let root = await showWorktreeSession(shown.id, in: vm)
        let cases: [(String, String, String)] = [
            ("folder_not_a_worktree", "missing", WorkbenchBranchPresentation.folderNotAWorktreeText),
            ("folder_not_a_worktree", "outside", WorkbenchBranchPresentation.folderOutsideTheRepositoryText),
            ("folder_unreadable", "reading the folder: permission denied",
             "This session's folder could not be read — the branch menu is unavailable "
                + "(reading the folder: permission denied)."),
            ("git_failed", "listing the worktrees: boom", "git could not read the folder: listing the worktrees: boom")
        ]
        for (refused, detail, text) in cases {
            runner.refuseBranches(refused, detail: detail)
            await vm.loadBranches(project: project)
            XCTAssertEqual(vm.branchListStates[root], .failed(text), refused + " " + detail)
        }
        vm.stopGitWatching(projectID: project.id)
    }

    /// A worktree root's refs watcher is its own and goes when the page
    /// shows the main folder again; the main folder's stays.
    func testTheWorktreeRootIsWatchedOnlyWhileShown() async throws {
        let worktree = try makeWorktree("mobile-a")
        let shown = try await agentRow(cwd: worktree.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let vm = worktreeVM(runner)
        let root = await showWorktreeSession(shown.id, in: vm)
        XCTAssertNotNil(vm.gitWatchers[root], "the worktree's refs are watched")
        XCTAssertNotNil(vm.gitWatchers[project.id])

        await vm.followGitRoot(project.mainCodeRoot)
        XCTAssertNil(vm.gitWatchers[root])
        XCTAssertNotNil(vm.gitWatchers[project.id])
        vm.stopGitWatching(projectID: project.id)
        XCTAssertTrue(vm.gitWatchers.isEmpty)
    }

    /// Go answering a worktree root's status with the main folder's
    /// envelope (`outside`/`missing`): not that root's status, so the menu
    /// is off there with a neutral note — no switch, no create, and the
    /// main folder's edits are never saved for it.
    func testAWorktreeStatusGoDoesNotPlaceThereTurnsTheMenuOff() async throws {
        try await assertMenuOff(scope: "outside", note: WorkbenchBranchPresentation.folderOutsideTheRepositoryText)
        try await assertMenuOff(scope: "missing", note: WorkbenchBranchPresentation.folderNotAWorktreeText)
        try await assertMenuOff(scope: "", note: WorkbenchBranchPresentation.folderUnreadableText(""))
        try await assertMenuOff(scope: "main", note: WorkbenchBranchPresentation.folderResolvedToMainText)
        try await assertMenuOff(scope: "worktree", note: WorkbenchBranchPresentation.folderResolvedElsewhereText)
    }

    private func assertMenuOff(scope: String, note: String, line: UInt = #line) async throws {
        let worktree = try makeWorktree("mobile-\(scope.isEmpty ? "unresolved" : scope)")
        try writeFile("m.go", "package m\n")
        let shown = try await agentRow(cwd: worktree.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let vm = worktreeVM(runner)
        let root = await showWorktreeSession(shown.id, in: vm)
        XCTAssertTrue(vm.gitRootIsPlaced(GitRootKey(root)), line: line)
        let inMain = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: "m.go")
        inMain.loadIfNeeded()
        vm.codeFiles.edited(inMain, text: "package m // main's\n", base: 0)
        let mainPage = EditorPage(edits: [])
        vm.codeFiles.register(mainPage, for: project.mainCodeRoot)

        runner.placeFolders(scope)
        await vm.refreshGitStatus(root: root)
        XCTAssertNil(vm.gitStatus[root], "the main folder's envelope is not the worktree's status", line: line)
        XCTAssertNil(vm.gitStatusErrors[root], "not a failed read", line: line)
        XCTAssertEqual(vm.gitScopeNotes[root], note, line: line)
        XCTAssertNil(vm.gitWatchers[root], line: line)
        XCTAssertFalse(vm.gitRootIsPlaced(GitRootKey(root)), line: line)

        await vm.switchBranch("feature/x", project: project, root: root)
        let created = await vm.createBranch("topic", project: project, root: root)
        XCTAssertFalse(created, line: line)
        XCTAssertTrue(runner.switches.isEmpty, "no switch call", line: line)
        XCTAssertTrue(runner.folders("create").isEmpty, "no create call", line: line)
        XCTAssertEqual(mainPage.asked, 0, "the main folder's page is not asked", line: line)
        XCTAssertEqual(try readFile("m.go"), "package m\n", "the main folder's edit is not saved", line: line)
        XCTAssertTrue(inMain.isDirty, line: line)

        runner.placeFolders(nil)
        await vm.refreshGitStatus(root: root)
        XCTAssertNil(vm.gitScopeNotes[root], line: line)
        XCTAssertEqual(vm.gitStatus[root]?.branch, "feature/wt", line: line)
        inMain.cancelAutosave()
        vm.stopGitWatching(projectID: project.id)
    }

    /// A switch in the main folder leaves a worktree nested in it alone:
    /// neither that worktree's buffers and page nor a main-root buffer of
    /// a file inside it — asked directly and through the switch.
    func testASwitchInTheMainFolderDoesNotSaveANestedWorktreesEdits() async throws {
        let worktree = try makeWorktree("mobile-a")
        try writeFile("a.go", "package a\n", in: worktree)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let vm = worktreeVM(runner)
        let root = CodeRoot(workbenchID: project.id, worktree: worktree)
        let inA = vm.codeFiles.buffer(for: root, relPath: "a.go")
        inA.loadIfNeeded()
        vm.codeFiles.edited(inA, text: "package a // A's\n", base: 0)
        let pageA = EditorPage(edits: [CodeEditorPendingEdit(id: inA.id, text: "package a // unsent\n", base: 0)])
        vm.codeFiles.register(pageA, for: root)
        let viaMain = vm.codeFiles.buffer(for: project.mainCodeRoot, relPath: ".claude/worktrees/mobile-a/a.go")
        viaMain.loadIfNeeded()
        vm.codeFiles.edited(viaMain, text: "package a // via main\n", base: 0)

        let direct = await vm.codeFiles.saveEdits(root: project.mainCodeRoot, workTree: folder.path)
        await vm.switchBranch("feature/x", project: project, root: project.mainCodeRoot)

        XCTAssertEqual(direct, .saved)
        XCTAssertEqual(runner.switches.count, 1)
        XCTAssertEqual(pageA.asked, 0, "the worktree's page is not asked")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("a.go"), encoding: .utf8), "package a\n")
        XCTAssertTrue(inA.isDirty)
        XCTAssertTrue(viaMain.isDirty)
        inA.cancelAutosave()
        viaMain.cancelAutosave()
    }

    /// A workbench whose folder holds this work tree: its page's unsent
    /// edit to a file in the tree is pulled before that file is saved — the
    /// same rule picks the pages asked and the buffers saved.
    func testAnOuterWorkbenchsUnsentEditIsPulledBeforeItsFileIsSaved() async throws {
        try writeFile("c.go", "package c\n")
        let outer = Workbench(row: Row(["id": 9_999, "name": "outer", "folder_path": folder.deletingLastPathComponent().path]))
        let vm = makeVM(ScriptedCLIRunner(results: []))
        let buffer = vm.codeFiles.buffer(for: outer.mainCodeRoot, relPath: folder.lastPathComponent + "/c.go")
        buffer.loadIfNeeded()
        vm.codeFiles.edited(buffer, text: "package c // typed\n", base: 0)
        let page = EditorPage(edits: [CodeEditorPendingEdit(id: buffer.id, text: "package c // unsent\n", base: 0)])
        vm.codeFiles.register(page, for: outer.mainCodeRoot)

        let saved = await vm.codeFiles.saveEdits(root: project.mainCodeRoot, workTree: folder.path)

        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(page.asked, 1)
        XCTAssertEqual(try readFile("c.go"), "package c // unsent\n", "the pulled edit is what went to disk")
        XCTAssertFalse(buffer.isDirty)
    }

    /// End to end: the session shown in worktree A runs in the
    /// TerminalCenter, its place is proven there, and a switch in A says an
    /// agent is running.
    func testALiveSessionProvenInTheWorktreeIsReportedForItsSwitch() async throws {
        let worktree = try makeWorktree("mobile-a")
        let shown = try await agentRow(cwd: worktree.path)
        let runner = WorktreeRunner(workbenchID: project.id, mainFolder: folder.path)
        let center = terminalCenter()
        center.start(shown, fresh: true)
        let vm = worktreeVM(runner, terminals: center)
        let root = await showWorktreeSession(shown.id, in: vm)
        await waitUntil {
            if case .worktree = vm.agentPlace(sessionID: shown.id) { return true }
            return false
        }
        guard case let .worktree(_, placeRoot, _) = vm.agentPlace(sessionID: shown.id) else {
            return XCTFail("the session's place is proven in its worktree")
        }
        XCTAssertEqual(placeRoot.path, worktree.path)

        await vm.switchBranch("feature/x", project: project, root: root)

        XCTAssertEqual(runner.folders("switch").last, worktree.path)
        XCTAssertEqual(runner.switches.last?.contains("--agent-running"), true)
        vm.stopGitWatching(projectID: project.id)
    }
}

/// Answers `workbench git` by subcommand: a `--folder` status is that
/// worktree's (branch `feature/wt`), any other the main folder's; branches,
/// switch and create succeed unless told to refuse. Records every argv.
private final class WorktreeRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var branchRefusal: (String, String)?
    private var folderReadsFail = false
    private var folderScope: String?
    let workbenchID: Int64
    let mainFolder: String

    init(workbenchID: Int64, mainFolder: String) {
        self.workbenchID = workbenchID
        self.mainFolder = mainFolder
    }

    /// The `--folder` of each `command` call, in order (nil: none).
    func folders(_ command: String) -> [String?] {
        lock.withLock {
            recorded.filter { $0.count > 2 && $0[2] == command }.map(Self.folder)
        }
    }

    var switches: [[String]] { lock.withLock { recorded.filter { $0.count > 2 && $0[2] == "switch" } } }

    func clearRecorded() { lock.withLock { recorded = [] } }

    func refuseBranches(_ refused: String, detail: String) { lock.withLock { branchRefusal = (refused, detail) } }

    /// From now on every `--folder` status read is Go's answer for a folder
    /// it does not place in a worktree: the main folder's envelope with
    /// `folder_scope` `scope` (nil: the worktree's own status again).
    func placeFolders(_ scope: String?) { lock.withLock { folderScope = scope } }

    /// From now on every `--folder` status read fails (exit non-zero).
    func failFolderReads() { lock.withLock { folderReadsFail = true } }

    private static func folder(_ args: [String]) -> String? {
        args.firstIndex(of: "--folder").map { args[$0 + 1] }
    }

    func run(args: [String]) async throws -> Data {
        let (refusal, readsFail): ((String, String)?, Bool) = lock.withLock {
            recorded.append(args)
            return (branchRefusal, folderReadsFail)
        }
        let command = args.count > 2 ? args[2] : ""
        if readsFail, command == "status", Self.folder(args) != nil {
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "simulated failure")
        }
        switch command {
        case "status": return status(folder: Self.folder(args))
        case "branches":
            if let (refused, detail) = refusal {
                return Data(#"{"git":false,"branches":[],"branches_ok":false,"refused":"\#(refused)","refused_detail":"\#(detail)"}"#.utf8)
            }
            return Data(#"{"git":true,"current":"main","branches":[{"name":"main","current":true}],"branches_ok":true}"#.utf8)
        case "switch": return Data(#"{"workbench_id":\#(workbenchID),"branch":"feature/x","switched":true,"status":{}}"#.utf8)
        case "create": return Data(#"{"workbench_id":\#(workbenchID),"branch":"topic","created":true,"status":{}}"#.utf8)
        default: return Data("{}".utf8)
        }
    }

    private func status(folder: String?) -> Data {
        guard let folder else {
            return Data(#"""
                {"workbench_id":\#(workbenchID),"git":true,"branch":"main","top_level":"\#(mainFolder)",
                 "git_dir":"\#(mainFolder)/.git","common_dir":"\#(mainFolder)/.git","status_ok":true,
                 "folder_scope":"main","folder_root":"\#(mainFolder)"}
                """#.utf8)
        }
        if let scope = lock.withLock({ folderScope }) {
            return Data(#"""
                {"workbench_id":\#(workbenchID),"git":true,"branch":"main","top_level":"\#(mainFolder)",
                 "git_dir":"\#(mainFolder)/.git","common_dir":"\#(mainFolder)/.git","status_ok":true,
                 "folder_requested":"\#(folder)","folder_scope":"\#(scope)","folder_root":"\#(mainFolder)"}
                """#.utf8)
        }
        let name = (folder as NSString).lastPathComponent
        return Data(#"""
            {"workbench_id":\#(workbenchID),"git":true,"branch":"feature/wt","top_level":"\#(folder)",
             "git_dir":"\#(mainFolder)/.git/worktrees/\#(name)","common_dir":"\#(mainFolder)/.git","status_ok":true,
             "folder_requested":"\#(folder)","folder_scope":"worktree","folder_root":"\#(folder)","worktree_name":"\#(name)"}
            """#.utf8)
    }
}
