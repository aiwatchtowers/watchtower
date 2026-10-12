import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Spec 2026-10-12 §5, §7 (board #399): a Codex session launches from
/// `launch-args`, resumes only a stored id with a rollout, and otherwise
/// starts anew with its stored id dropped. No real `codex` runs: the
/// launch-args call and the rollout check are stubbed.
@MainActor
final class TerminalCenterStartDecisionTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var rollouts: Set<String> = []
    private var argsCalls: [Int64] = []
    private var argsResult: Result<CodexLaunchArgs, Error> = .success(TerminalCenterStartDecisionTests.codexArgs)
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    nonisolated static let codexArgs = CodexLaunchArgs(
        binary: "/Users/example/bin/codex", pathPrepend: "/Users/example/bin",
        args: ["--no-daemon", "-c", "check_for_update_on_startup=false"]
    )
    private let storedID = "0199d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e5f"

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "TerminalCenterStartDecisionTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt start \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        rollouts = []
        argsCalls = []
        argsResult = .success(Self.codexArgs)
        center = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in false }
        center.codexRolloutExists = { [weak self] id, _ in self?.rollouts.contains(id) ?? false }
        stubLaunchArgs()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Helpers

    private func stubLaunchArgs() {
        center.codexLaunchArgs = { [weak self] workbenchID in
            guard let self else { throw CancellationError() }
            argsCalls.append(workbenchID)
            return try argsResult.get()
        }
    }

    /// The VM sets the center's launch-args call from its CLI: the stub goes back on after.
    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        vm.now = { [weak self] in self?.clock ?? Date() }
        stubLaunchArgs()
        return vm
    }

    private func workbench(_ name: String = "acme") async throws -> Int64 {
        let dir = folder.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: name, folder: dir) }
    }

    /// A codex row, optionally with an id (and rollout path) a SessionStart stored.
    private func codexRow(_ projectID: Int64?, id: String? = nil, transcript: String? = nil) async throws -> TerminalSession {
        let dir = folder.appendingPathComponent("acme").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try await pool.write { db in
            let row = try TerminalSessionQueries.create(db, .init(projectID: projectID, kind: .codex, title: "c", folderPath: dir))
            try db.execute(sql: "UPDATE terminal_sessions SET claude_session_id = ?, agent_transcript_path = ? WHERE id = ?",
                           arguments: [id, transcript, row.id])
            return try XCTUnwrap(try TerminalSessionQueries.fetch(db, id: row.id))
        }
    }

    private func stored(_ id: Int64) async throws -> TerminalSession? {
        try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    /// The `/bin/sh` script of the last Codex launch (`TerminalLaunch.codexCommandEnv`).
    private var lastScript: String {
        let prefix = "\(TerminalLaunch.codexCommandEnv)="
        return launches.last?.environment.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? ""
    }

    // MARK: - The decision

    func testCodexNullIDAlwaysNew() async throws {
        let row = try await codexRow(try await workbench())
        rollouts = [storedID]

        let mode = await center.launch(row, fresh: false)

        XCTAssertEqual(mode, .newAgent(.codex, sessionID: nil, prompt: nil))
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(argsCalls, [row.projectID])
    }

    func testCodexStoredIDWithRolloutResumes() async throws {
        let row = try await codexRow(try await workbench(), id: storedID)
        rollouts = [storedID]

        let mode = await center.launch(row, fresh: false)

        XCTAssertEqual(mode, .resumeAgent(.codex, sessionID: storedID))
        XCTAssertTrue(lastScript.hasSuffix(" resume '\(storedID)'"), lastScript)
    }

    /// A fresh start never resumes, and carries its prompt.
    func testCodexFreshStartIsNewWithItsPrompt() async throws {
        let row = try await codexRow(try await workbench(), id: storedID)
        rollouts = [storedID]

        let mode = await center.launch(row, fresh: true, prompt: "Work on target #3.")

        XCTAssertEqual(mode, .newAgent(.codex, sessionID: nil, prompt: "Work on target #3."))
        XCTAssertEqual(launches.last?.environment.last, "WATCHTOWER_FIRST_PROMPT=Work on target #3.")
    }

    /// A stored id that is not a canonical UUID never reaches the command.
    func testCodexInvalidStoredIDStartsNew() async throws {
        let bad = "x'; rm -rf ~"
        let row = try await codexRow(try await workbench(), id: bad)
        rollouts = [bad]

        let launched1 = await center.launch(row, fresh: false)
        XCTAssertEqual(launched1, .newAgent(.codex, sessionID: nil, prompt: nil))
    }

    func testCodexMissingRolloutStartsFreshAndNullsID() async throws {
        let p = try await workbench()
        let row = try await codexRow(p, id: storedID, transcript: "/Users/example/.codex/sessions/2026/10/12/rollout-x-\(storedID).jsonl")
        let vm = makeVM()

        await vm.open(row)

        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertFalse(lastScript.contains(" resume "), lastScript)
        XCTAssertTrue(lastScript.hasSuffix("'check_for_update_on_startup=false'"), lastScript)
        let after = try await stored(row.id)
        XCTAssertNil(after?.claudeSessionID)
        XCTAssertNil(after?.transcriptPath)
    }

    /// A resume keeps the id; a new start of a row with nothing stored writes nothing.
    func testCodexResumeKeepsTheStoredID() async throws {
        let row = try await codexRow(try await workbench(), id: storedID)
        rollouts = [storedID]
        let vm = makeVM()

        await vm.open(row)

        let after = try await stored(row.id)
        XCTAssertEqual(after?.claudeSessionID, storedID)
    }

    // MARK: - Failures

    func testCodexNotFoundShowsNoticeWithoutProcess() async throws {
        let row = try await codexRow(try await workbench())
        argsResult = .failure(WorkbenchCLIError.agentNotFound(.codex))

        let mode = await center.launch(row, fresh: true)

        XCTAssertNil(mode)
        XCTAssertTrue(processes.isEmpty, "no process starts")
        XCTAssertEqual(center.states[row.id], .unavailable(TerminalLaunch.exitMessage(code: 127, agent: .codex)))
    }

    func testOtherLaunchArgsFailureSaysSo() async throws {
        let row = try await codexRow(try await workbench())
        argsResult = .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "broken config"))

        let launched2 = await center.launch(row, fresh: true)
        XCTAssertNil(launched2)
        guard case let .unavailable(message)? = center.states[row.id] else { return XCTFail("not unavailable") }
        XCTAssertTrue(message.hasPrefix("Could not prepare the Codex launch:"), message)
        XCTAssertTrue(processes.isEmpty)
    }

    /// Codex's MCP server and hooks are a workbench's: a standalone codex
    /// row, or a center without a CLI, launches nothing.
    func testCodexWithoutWorkbenchOrCLILaunchesNothing() async throws {
        let standalone = try await codexRow(nil)
        let launched3 = await center.launch(standalone, fresh: true)
        XCTAssertNil(launched3)
        XCTAssertEqual(center.states[standalone.id], .unavailable("Codex sessions run in a workbench."))

        let row = try await codexRow(try await workbench())
        center.codexLaunchArgs = nil
        let launched4 = await center.launch(row, fresh: true)
        XCTAssertNil(launched4)
        XCTAssertTrue(argsCalls.isEmpty)
        XCTAssertTrue(processes.isEmpty)
    }

    /// A close while `launch-args` runs, or a second launch meanwhile,
    /// starts nothing more.
    func testACloseWhileWaitingStartsNothing() async throws {
        let row = try await codexRow(try await workbench())
        center.codexLaunchArgs = { [weak self] _ in
            await self?.center.close(sessionID: row.id)
            return Self.codexArgs
        }
        let launched5 = await center.launch(row, fresh: true)
        XCTAssertNil(launched5)
        XCTAssertTrue(processes.isEmpty)
        XCTAssertNil(center.states[row.id])

        var second: TerminalLaunch.Mode?? = .none
        center.codexLaunchArgs = { [weak self] _ in
            second = await self?.center.launch(row, fresh: true)
            return Self.codexArgs
        }
        let launched6 = await center.launch(row, fresh: true)
        XCTAssertNotNil(launched6)
        XCTAssertEqual(second, .some(nil), "the overlapping launch is refused")
        XCTAssertEqual(processes.count, 1)
    }

    /// A non-codex row starts at once, without asking `launch-args`.
    func testClaudeAndShellRowsSkipLaunchArgs() async throws {
        let p = try await workbench()
        let dir = folder.appendingPathComponent("acme").path
        let uuid = UUID().uuidString.lowercased()
        let (claude, shell) = try await pool.write { db in
            (try TerminalSessionQueries.create(db, .init(projectID: p, kind: .claude, title: "a", folderPath: dir, claudeSessionID: uuid)),
             try TerminalSessionQueries.create(db, .init(projectID: p, kind: .shell, title: "z", folderPath: dir)))
        }
        let launched7 = await center.launch(claude, fresh: false)
        XCTAssertEqual(launched7, .newClaude(uuid: uuid, prompt: nil))
        let launched8 = await center.launch(shell, fresh: true)
        XCTAssertEqual(launched8, .shell)
        XCTAssertTrue(argsCalls.isEmpty)
        XCTAssertEqual(launches.first?.args.last, "exec claude --session-id \(uuid)")
    }

    // MARK: - Resume failures, Start fresh

    func testResumeFailureTrackingCoversCodex() async throws {
        let row = try await codexRow(try await workbench(), id: storedID)
        rollouts = [storedID]
        let vm = makeVM()

        await vm.open(row)
        clock += 1
        processes.last?.exit(1)
        XCTAssertEqual(vm.resumeFailed, [row.id])

        await vm.startFresh(row)

        XCTAssertTrue(vm.resumeFailed.isEmpty)
        let after = try await stored(row.id)
        XCTAssertNil(after?.claudeSessionID, "Start fresh drops the Codex id; Codex mints the next")
        XCTAssertFalse(lastScript.contains(" resume "), lastScript)
        XCTAssertTrue(lastScript.hasSuffix("'check_for_update_on_startup=false'"), lastScript)
        XCTAssertEqual(center.states[row.id], .running)
    }

    /// A new Codex session exiting at once is no failed resume: there was
    /// nothing to resume.
    func testANewCodexSessionExitingAtOnceIsNoFailedResume() async throws {
        let row = try await codexRow(try await workbench())
        let vm = makeVM()

        await vm.open(row)
        processes.last?.exit(1)

        XCTAssertTrue(vm.resumeFailed.isEmpty)
    }

    func testReopenLabel() async throws {
        let p = try await workbench()
        let fresh = try await codexRow(p)
        let started = try await codexRow(p, id: storedID)
        XCTAssertEqual(TerminalSessionPolicy.reopenLabel(fresh), "Start")
        XCTAssertEqual(TerminalSessionPolicy.reopenLabel(started), "Resume")
        let shell = try await pool.write {
            try TerminalSessionQueries.create($0, .init(projectID: p, kind: .shell, title: "z", folderPath: "/tmp"))
        }
        XCTAssertEqual(TerminalSessionPolicy.reopenLabel(shell), "Start")
    }

    // MARK: - Navigation

    /// House rule: a Codex start the owner leaves while `launch-args` runs
    /// still lands in its own workbench, and coming back finds it running —
    /// one process, not relaunched.
    func testStartedSessionStateSurvivesNavigation() async throws {
        let a = try await workbench("a")
        let b = try await workbench("b")
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = a
        center.codexLaunchArgs = { [weak vm] _ in
            vm?.selectedWorkbenchID = b  // the owner leaves mid-launch
            return Self.codexArgs
        }
        let fetched = try await pool.read { try WorkbenchQueries.fetch($0, id: a) }
        let project = try XCTUnwrap(fetched)

        await vm.startNewSession(project: project, title: "codex", agent: .codex)

        let row = try XCTUnwrap(vm.terminalSessions[a]?.first)
        XCTAssertEqual(row.kind, .codex)
        XCTAssertNil(row.claudeSessionID)
        XCTAssertEqual(vm.selectedWorkbenchID, b)
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(vm.layout(projectID: a).primary, .session(row.id))

        vm.selectedWorkbenchID = a
        await vm.open(row)

        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(launches.count, 1, "a running session is not relaunched")
    }

    // MARK: - The CLI call

    func testLaunchArgsCallAndExit3() async throws {
        let json = #"{"binary":"/opt/codex","path_prepend":"/opt","args":["--no-daemon"]}"#
        let runner = FakeCLIRunner(stdout: Data(json.utf8))
        let args = try await WorkbenchCLI(runner: runner).launchArgs(agent: .codex, workbenchID: 7)
        XCTAssertEqual(args, CodexLaunchArgs(binary: "/opt/codex", pathPrepend: "/opt", args: ["--no-daemon"]))
        XCTAssertEqual(runner.invocations, [["workbench", "launch-args", "--agent", "codex", "--workbench", "7", "--json"]])

        let missing = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 3, stderr: ""))
        do {
            _ = try await WorkbenchCLI(runner: missing).launchArgs(agent: .codex, workbenchID: 7)
            XCTFail("exit 3 must throw")
        } catch {
            XCTAssertEqual(error as? WorkbenchCLIError, .agentNotFound(.codex))
        }
        let usage = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 2, stderr: "usage"))
        do {
            _ = try await WorkbenchCLI(runner: usage).launchArgs(agent: .codex, workbenchID: 7)
            XCTFail("exit 2 must throw")
        } catch {
            XCTAssertNil(error as? WorkbenchCLIError, "only exit 3 is not-found")
        }
    }
}
