import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// New Session through Go (Go hub 3 Task 8): every Desktop start of a
/// workbench agent session runs `watchtower workbench session start`, shows
/// the row Go wrote at once (instant start, #942), then attaches the pane to
/// the run Go launched — nothing launches from Swift — with the Swift path's
/// copy for every notice and failure. The CLI is a scripted runner that
/// writes the row as Go's Begin does; the session host is a fake transport;
/// `onSleep` plays Go's detached finish (by default it launches the row on
/// the wait's first sleep).
@MainActor
final class StartNewSessionViaCLITests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var transports: [FakeSessionHostTransport] = []
    private var factoryCalls = 0
    private var center: TerminalCenter!
    private var client: SessionHostClient!
    private var runner: ScriptedSessionStartRunner!
    private var vm: WorkbenchesViewModel!
    private var projectID: Int64 = 0
    /// Called on each sleep of the wait with the latest started row and the
    /// sleep's number for that row (1 = first).
    private var onSleep: ((Int64, Int) async -> Void)?
    private var sleeps: [Int64: Int] = [:]
    /// What the wait saw at the row's first sleep: preparing and on screen.
    private var seenWhileStarting: (preparing: Bool, onScreen: Bool)?

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "StartNewSessionViaCLITests-\(UUID().uuidString)"))
        transports = []
        factoryCalls = 0
        sleeps = [:]
        seenWhileStarting = nil
        center = TerminalCenter { [weak self] in
            self?.factoryCalls += 1
            return FakeTerminalSession()
        }
        center.shell = { "/bin/zsh" }
        client = SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { [weak self] _ in
            let transport = FakeSessionHostTransport()
            self?.transports.append(transport)
            return transport
        })
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        center.sessionHost = client
        let folder = FileManager.default.temporaryDirectory.path
        projectID = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder) }
        runner = ScriptedSessionStartRunner(pool: pool)
        vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults, terminalCenter: center)
        vm.now = { Date(timeIntervalSince1970: 1_760_000_000) }
        onSleep = { [weak self] id, n in if n == 1 { self?.launchRun(row: id) } }
        vm.goSessionStart = GoSessionStartWait(poll: .milliseconds(1), deadline: .seconds(5)) { [weak self] _ in
            guard let self, let id = runner.startedIDs.last else { return }
            sleeps[id, default: 0] += 1
            let n = sleeps[id] ?? 0
            if n == 1 {
                seenWhileStarting = (vm.preparingSessions.contains(id), vm.layout(projectID: projectID).showsSession(id))
            }
            await onSleep?(id, n)
            await Task.yield()
        }
    }

    override func tearDown() async throws {
        for id in center.liveIDs { (center.process(for: id) as? HostedTerminalSession)?.detachFromHost() }
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private var control: FakeSessionHostTransport { transports[0] }

    private func launchRun(row: Int64, exited: Bool = false, code: Int? = nil) {
        control.listed.removeAll { $0.row == row }
        control.listed.append(SessionHostSessionInfo(row: row, run: "run-\(row)", pid: 4242,
                                                     startedAtMs: 1_760_000_000_000, exited: exited, code: code))
    }

    private func recordOnRow(_ id: Int64, failure: String, notice: String? = nil) async {
        let pool = pool
        try? await pool?.write { db in
            try db.execute(sql: """
                UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = '2026-11-01T10:00:00Z',
                    agent_failed_at = '2026-11-01T10:00:00Z', agent_error = ?, start_notice = ? WHERE id = ?
                """, arguments: [failure, notice, id])
        }
    }

    private var startCalls: [[String]] {
        runner.invocations.filter { $0.starts(with: ["workbench", "session", "start"]) }
    }

    private func row(_ id: Int64) async throws -> TerminalSession? {
        try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
    }

    private var title: String { TerminalSessionNaming.provisional(now: Date(timeIntervalSince1970: 1_760_000_000)) }

    func testNewSessionRunsWorkbenchSessionStart() async throws {
        await vm.newSession(projectID: projectID, agent: .claude)

        XCTAssertEqual(startCalls, [[
            "workbench", "session", "start", "--workbench", String(projectID), "--agent", "claude", "--place", "auto",
            "--title", title, "--json"
        ]])
        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertEqual(seenWhileStarting?.preparing, true, "Starting… while Go places and launches it")
        XCTAssertEqual(seenWhileStarting?.onScreen, true, "on screen before the launch (instant start)")
        XCTAssertTrue(vm.layout(projectID: projectID).showsSession(id), "the row selected is session_id")
        XCTAssertEqual(center.focusOrder.last, id)
        XCTAssertEqual(center.states[id], .running)
        XCTAssertFalse(vm.preparingSessions.contains(id))
        XCTAssertNil(vm.sessionErrors[projectID])
    }

    func testPlaceOverrideIsPassed() async throws {
        for choice in [WorktreeChoice.folder, .worktree, .auto] {
            await vm.newSession(projectID: projectID, agent: .codex, worktree: choice)
        }
        XCTAssertEqual(startCalls.map { Self.value(of: "--place", in: $0) }, ["folder", "worktree", "auto"])
        XCTAssertEqual(startCalls.map { Self.value(of: "--agent", in: $0) }, ["codex", "codex", "codex"])
    }

    /// A start Go refused before any row: the CLI's sentence on the page; a
    /// missing agent (exit 3) is the Swift launch's line. A failure Go
    /// recorded on the row: its reason in the pane, the row kept, no cleanup.
    func testStartFailureShowsTheReasonAndKeepsTheRow() async throws {
        runner.refusal = CLIRunnerError.nonZeroExit(code: 1, stderr: "workbench 9 not found\n")
        await vm.newSession(projectID: projectID, agent: .claude)
        XCTAssertEqual(vm.sessionErrors[projectID], "Could not start the session: workbench 9 not found")

        runner.refusal = CLIRunnerError.nonZeroExit(code: 3, stderr: "codex was not found\n")
        await vm.newSession(projectID: projectID, agent: .codex)
        XCTAssertEqual(vm.sessionErrors[projectID], TerminalLaunch.exitMessage(code: 127, agent: .codex))
        XCTAssertTrue(runner.startedIDs.isEmpty)

        runner.refusal = nil
        onSleep = { [weak self] id, n in if n == 1 { await self?.recordOnRow(id, failure: "launch refused: no shell") } }
        await vm.newSession(projectID: projectID, agent: .claude)
        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertEqual(center.states[id], .unavailable("[Watchtower] launch refused: no shell"))
        let kept = try await row(id)
        XCTAssertNotNil(kept, "the row stays")
        XCTAssertEqual(runner.invocations.filter { !$0.starts(with: ["workbench", "session", "start"]) }, [],
                       "no Swift cleanup or worktree call")
        XCTAssertTrue(vm.layout(projectID: projectID).showsSession(id))
    }

    /// Go recorded the agent missing on the row (its launch watch saw exit
    /// 127): the pane has the Swift launch's line, a session() step is told
    /// `agentNotFound` (notInstalledHint), and so is it for a run that
    /// exited 127 before the watch wrote it.
    func testAMissingAgentAfterTheRowIsTheSwiftLaunchsLine() async throws {
        onSleep = { [weak self] id, n in
            if n == 1 { await self?.recordOnRow(id, failure: GoSessionStartContract.agentNotFoundReason("codex")) }
        }
        await vm.newSession(projectID: projectID, agent: .codex)
        let id = try XCTUnwrap(runner.startedIDs.last)
        XCTAssertEqual(center.states[id], .unavailable(TerminalLaunch.exitMessage(code: 127, agent: .codex)))

        onSleep = { [weak self] id, n in if n == 1 { self?.launchRun(row: id, exited: true, code: 127) } }
        let request = PendingSessionRequest(stepID: 1, runID: 77, automationID: 3, projectID: projectID,
                                            automationName: "Sweep", prompt: "sweep", title: "Nightly sweep", agent: .claude)
        do {
            _ = try await vm.startAutomationSession(request)
            XCTFail("an agent that exited 127 is not a started session")
        } catch let error as WorkbenchesViewModel.TargetStartError {
            XCTAssertEqual(error, .agentNotFound(.claude))
        }
    }

    func testNoSwiftLaunchOnNewSession() async throws {
        await vm.newSession(projectID: projectID, agent: .claude)

        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertEqual(factoryCalls, 0, "TerminalCenter.launch: no Swift process for a new session")
        XCTAssertEqual(transports.reduce(0) { $0 + $1.sent(.launch).count }, 0, "no Launch from Swift")
        let hosted = try XCTUnwrap(center.process(for: id) as? HostedTerminalSession)
        await hosted.connecting?.value
        let attaches = transports.flatMap { $0.sent(.attach) }
        XCTAssertEqual(try attaches.map { try $0.decoded(SessionHostAttachRequest.self) },
                       [SessionHostAttachRequest(row: id, run: "run-\(id)")], "attached once to Go's run")
    }

    /// PROJ-17: a row deleted while Starting… never shows and never runs — the
    /// run Go launched for it meanwhile is stopped through the host.
    func testADeleteDuringPlacementNeverLaunches() async throws {
        onSleep = { [weak self] id, n in
            guard let self, n == 1, let row = try? await row(id) else { return }
            await vm.delete(row)
            launchRun(row: id)
        }
        await vm.newSession(projectID: projectID, agent: .claude)

        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertNotEqual(center.states[id], .running)
        XCTAssertNil(center.process(for: id))
        XCTAssertFalse(vm.layout(projectID: projectID).showsSession(id))
        XCTAssertEqual(runner.invocations.filter { $0.starts(with: ["workbench", "session", "stop"]) },
                       [["workbench", "session", "stop", "--session", String(id), "--json"]])
        XCTAssertNil(vm.sessionActionErrors[projectID])
        XCTAssertNil(vm.startNotice[projectID])
    }

    /// No Desktop placement turn: a second start shows its row while the
    /// first is still Starting… (Go's placement lock orders them).
    func testASecondStartShowsItsRowWhileTheFirstIsStarting() async throws {
        var releaseFirst = false
        onSleep = { [weak self] _, _ in
            guard let self else { return }
            let ids = runner.startedIDs
            if ids.count >= 2 { launchRun(row: ids[1]) }
            if releaseFirst, let first = ids.first { launchRun(row: first) }
        }
        let firstStart = Task { await self.vm.newSession(projectID: self.projectID, agent: .claude) }
        while sleeps.isEmpty { await Task.yield() }
        await vm.newSession(projectID: projectID, agent: .claude)

        XCTAssertEqual(startCalls.count, 2)
        let firstID = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertTrue(vm.preparingSessions.contains(firstID), "the first is still Starting…")
        let second = try XCTUnwrap(runner.startedIDs.last)
        XCTAssertEqual(center.states[second], .running)
        releaseFirst = true
        await firstStart.value
        XCTAssertEqual(center.states[firstID], .running)
    }

    /// Go's line about the place (start_notice) lands on startNotice; a
    /// placed row whose setup command never ran gets the Swift path's line.
    func testGoStartNoticeLandsOnTheStartNotice() async throws {
        onSleep = { [weak self] id, n in
            guard let self, n == 1 else { return }
            try? await pool.write { db in
                try db.execute(sql: "UPDATE terminal_sessions SET start_notice = ? WHERE id = ?",
                               arguments: ["Started in the folder: the repository has no commit yet.", id])
            }
            launchRun(row: id)
        }
        await vm.newSession(projectID: projectID, agent: .claude, worktree: .worktree)
        XCTAssertEqual(vm.startNotice[projectID], "Started in the folder: the repository has no commit yet.")

        let setup = GoSessionStartContract.setupNotRunPrefix + "make deps"
        onSleep = { [weak self] id, n in
            if n == 1 { await self?.recordOnRow(id, failure: "launch refused: no shell", notice: setup) }
        }
        await vm.newSession(projectID: projectID, agent: .claude)
        XCTAssertEqual(vm.startNotice[projectID], setup)

        onSleep = { [weak self] id, n in if n == 1 { self?.launchRun(row: id) } }
        await vm.newSession(projectID: projectID, agent: .claude)
        XCTAssertNil(vm.startNotice[projectID], "a later start with nothing to say clears it, as before")
    }

    /// A row Go could not move into its worktree: as on the Swift path, the
    /// failure naming the kept worktree is on the page, the row deleted and
    /// out of the layout.
    func testAFailedMoveIsReportedAndTheRowDeleted() async throws {
        let sentence = GoSessionStartContract.moveFailedPrefix + "boom — the worktree /tmp/acme/.claude/worktrees/session-2"
            + " on wt/session-2 was kept."
        onSleep = { [weak self] id, n in
            if n == 1 { await self?.recordOnRow(id, failure: String(sentence.prefix(60)), notice: sentence) }
        }
        await vm.newSession(projectID: projectID, agent: .claude)

        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertEqual(vm.sessionErrors[projectID], sentence)
        let gone = try await row(id)
        XCTAssertNil(gone)
        XCTAssertFalse(vm.layout(projectID: projectID).showsSession(id))
        XCTAssertNil(vm.startNotice[projectID])
    }

    /// No session host at the moment of waiting: the start waits for one.
    func testTheWaitWaitsForTheSessionHost() async throws {
        center.sessionHost = nil
        onSleep = { [weak self] id, n in
            guard let self, n == 3 else { return }
            center.sessionHost = client
            launchRun(row: id)
        }
        await vm.newSession(projectID: projectID, agent: .claude)
        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertEqual(center.states[id], .running)
    }

    /// Nothing within the wall-clock deadline: the pane says so.
    func testNothingWithinTheDeadlineFailsTheStart() async throws {
        vm.goSessionStart?.deadline = .milliseconds(30)
        vm.goSessionStart?.sleep = { try? await Task.sleep(for: $0) }
        vm.goSessionStart?.poll = .milliseconds(5)
        await vm.newSession(projectID: projectID, agent: .claude)
        let id = try XCTUnwrap(runner.startedIDs.first)
        XCTAssertEqual(center.states[id], .unavailable("[Watchtower] " + GoSessionStartWait.timedOutReason))
    }

    func testDecodesOnlyPinnedKeys() throws {
        XCTAssertEqual(Set(SessionStartResult.CodingKeys.allCases.map(\.rawValue)),
                       ["session_id", "state", "folder_path", "worktree_branch"])
        let decoded = try JSONDecoder().decode(SessionStartResult.self, from: Data("""
            {"session_id":7,"state":"starting","folder_path":"/tmp/acme","worktree_branch":"","extra":1}
            """.utf8))
        XCTAssertEqual(decoded, SessionStartResult(sessionID: 7, state: "starting", folderPath: "/tmp/acme", worktreeBranch: ""))
        XCTAssertThrowsError(try JSONDecoder().decode(SessionStartResult.self, from: Data("""
            {"session_id":7,"state":"starting","folder_path":"/tmp/acme"}
            """.utf8)), "a missing pinned key is an error")
    }

    /// Work on It, a session() step and a start with a first prompt: the
    /// target, the title and the run go on argv, the prompt on stdin only.
    func testTargetBriefAndAutomationRunAreHandedToGo() async throws {
        let workbench = projectID
        let targetID = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: workbench, text: "Ship it") }
        await vm.workOn(targetID: targetID, targetText: "Ship it", projectID: projectID, agent: .claude)
        let request = PendingSessionRequest(stepID: 1, runID: 77, automationID: 3, projectID: projectID,
                                            automationName: "Sweep", prompt: "sweep the board", title: "Nightly sweep",
                                            agent: .claude)
        _ = try await vm.startAutomationSession(request)

        XCTAssertEqual(startCalls.count, 2)
        let work = startCalls[0]
        XCTAssertEqual(Self.value(of: "--target", in: work), String(targetID))
        XCTAssertEqual(Self.value(of: "--title", in: work), "Ship it")
        XCTAssertTrue(work.contains("--brief-stdin"), "the work-on prompt goes on stdin")
        let step = startCalls[1]
        XCTAssertEqual(Self.value(of: "--automation-run", in: step), "77")
        XCTAssertEqual(Self.value(of: "--title", in: step), "Nightly sweep")
        XCTAssertFalse(step.contains("sweep the board"), "never on argv")
        XCTAssertEqual(runner.stdinInputs.last.flatMap { String(bytes: $0, encoding: .utf8) }, "sweep the board")
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}

/// `workbench session start` as Go's Begin answers it: the row written in
/// the workbench folder, its id in the pinned JSON. Every other call answers
/// empty. `refusal` makes the start fail before any row.
final class ScriptedSessionStartRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let pool: DatabasePool
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var recordedStdin: [Data] = []
    private var ids: [Int64] = []
    var refusal: Error?

    init(pool: DatabasePool) { self.pool = pool }

    var invocations: [[String]] { lock.withLock { recorded } }
    var stdinInputs: [Data] { lock.withLock { recordedStdin } }
    var startedIDs: [Int64] { lock.withLock { ids } }

    func run(args: [String]) async throws -> Data {
        try await answer(args)
    }

    func run(args: [String], stdin: Data) async throws -> Data {
        lock.withLock { recordedStdin.append(stdin) }
        return try await answer(args)
    }

    private func answer(_ args: [String]) async throws -> Data {
        lock.withLock { recorded.append(args) }
        guard args.starts(with: ["workbench", "session", "start"]) else { return Data() }
        if let refusal { throw refusal }
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let workbench = Int64(value("--workbench") ?? "") ?? 0
        let agent = value("--agent") == "codex" ? TerminalSession.Kind.codex : .claude
        let row = try await pool.write { db -> TerminalSession in
            let folder = try String.fetchOne(db, sql: "SELECT folder_path FROM projects WHERE id = ?", arguments: [workbench]) ?? ""
            return try TerminalSessionQueries.create(db, .init(
                projectID: workbench, kind: agent, title: value("--title") ?? "s",
                targetID: value("--target").flatMap { Int64($0) }, folderPath: folder,
                claudeSessionID: agent == .claude ? UUID().uuidString.lowercased() : nil
            ))
        }
        lock.withLock { ids.append(row.id) }
        return Data("""
            {"session_id":\(row.id),"state":"starting","folder_path":"\(row.folderPath)","worktree_branch":""}
            """.utf8)
    }
}
