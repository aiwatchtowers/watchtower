import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Plays Go's half of `automations session-launched` / `session-ended`
/// against the test database (`AttachAutomationSessionStep`,
/// `EndAutomationSessionStep`, simplified), and records every call. A held
/// call waits for `release()`. No process is spawned.
private final class GoStandIn: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let pool: DatabasePool
    private var calls: [[String]] = []
    private var attachAnswer = true
    private var endFailures = 0
    private var gate: AsyncGate?

    init(pool: DatabasePool) {
        self.pool = pool
    }

    /// The automations calls so far (other CLI calls the AppState wiring
    /// makes are answered `{}` and not recorded).
    var invocations: [[String]] { lock.withLock { calls } }

    /// `session-launched` answers `{"attached": false}` and attaches nothing.
    func refuseAttach() { lock.withLock { attachAnswer = false } }

    /// The next `n` `session-ended` calls fail like a CLI that did not run.
    func failEnds(_ n: Int) { lock.withLock { endFailures = n } }

    /// From now on each `session-launched` waits for `release()`.
    func holdAttach() -> AsyncGate {
        let gate = AsyncGate()
        lock.withLock { self.gate = gate }
        return gate
    }

    func run(args: [String]) async throws -> Data {
        guard args.first == "automations" else { return Data("{}".utf8) }
        lock.withLock { calls.append(args) }
        let flag = { (name: String) in args.firstIndex(of: name).flatMap { Int64(args[$0 + 1]) } ?? 0 }
        switch args[1] {
        case "session-launched":
            if let gate = lock.withLock({ gate }) { await gate.wait() }
            guard lock.withLock({ attachAnswer }) else { return Data(#"{"attached":false}"#.utf8) }
            let (step, session) = (flag("--step"), flag("--session"))
            try await pool.write { db in
                try db.execute(sql: "UPDATE automation_run_steps SET session_id = ? WHERE id = ?", arguments: [session, step])
                try db.execute(sql: """
                    UPDATE automation_runs SET waiting_reason = 'session'
                    WHERE id = (SELECT run_id FROM automation_run_steps WHERE id = ?)
                    """, arguments: [step])
            }
            return Data(#"{"attached":true}"#.utf8)
        case "session-ended":
            let failing = lock.withLock { () -> Bool in
                guard endFailures > 0 else { return false }
                endFailures -= 1
                return true
            }
            if failing { throw CLIRunnerError.binaryNotFound }
            let step = flag("--step")
            let status = args.contains("stopped") ? "ok" : "error"
            try await pool.write { db in
                try db.execute(sql: "UPDATE automation_run_steps SET status = ? WHERE id = ? AND status = 'waiting'",
                               arguments: [status, step])
            }
            return Data(#"{"ended":true}"#.utf8)
        default:
            return Data("{}".utf8)
        }
    }
}

private struct LaunchFailure: LocalizedError {
    let errorDescription: String?
}

/// Stands in for `WorkbenchesViewModel.startAutomationSession`: writes the
/// session row with the run marker (before any launch check, as the real
/// one does), then fails when told to, or waits on a gate. `live` plays the
/// terminal center's running sessions: a launch that goes through runs.
@MainActor
private final class FakeStarter {
    private let pool: DatabasePool
    var calls: [PendingSessionRequest] = []
    var failure: String?
    var gate: AsyncGate?
    var live: Set<Int64> = []

    init(pool: DatabasePool) {
        self.pool = pool
    }

    func start(_ r: PendingSessionRequest) async throws -> TerminalSession {
        calls.append(r)
        let row = try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: r.projectID, kind: .claude, title: r.title, folderPath: "/tmp/acme",
                claudeSessionID: UUID().uuidString.lowercased(), automationRunID: r.runID
            ))
        }
        if let gate { await gate.wait() }
        if let failure { throw LaunchFailure(errorDescription: failure) }
        live.insert(row.id)
        return row
    }
}

/// Counts the loop's sleeps; each lasts until the loop is stopped, so a
/// started center makes one pass (the reconcile and a first tick).
@MainActor
private final class Pacer {
    var sleeps = 0
    func sleep() async {
        sleeps += 1
        try? await Task.sleep(for: .seconds(60))
    }
}

@MainActor
final class AutomationSessionCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var go: GoStandIn!
    private var starter: FakeStarter!
    private var pacer: Pacer!
    private var centers: [AutomationSessionCenter] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        go = GoStandIn(pool: pool)
        starter = FakeStarter(pool: pool)
        pacer = Pacer()
        centers = []
    }

    override func tearDown() {
        // No loop outlives its test.
        centers.forEach { $0.stop() }
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeCenter() -> AutomationSessionCenter {
        let (starter, pacer): (FakeStarter, Pacer) = (self.starter, self.pacer)
        let center = AutomationSessionCenter(
            dbPool: pool, cli: AutomationsCLI(runner: go),
            start: { try await starter.start($0) },
            isLive: { starter.live.contains($0) },
            sleep: { _ in await pacer.sleep() }
        )
        centers.append(center)
        return center
    }

    private struct Request {
        let workbench: Int64
        let run: Int64
        let step: Int64
    }

    /// A workbench run waiting for the app on one `session()` step.
    private func request(workbench: Int64? = nil) async throws -> Request {
        try await pool.write { db in
            let p = try workbench ?? TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let a = try TestDatabase.insertAutomation(db, slug: "review-\(UUID().uuidString.prefix(6))", name: "Review",
                                                      workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            let step = try TestDatabase.insertAutomationStep(
                db, runID: run, seq: 1, kind: "session",
                argsJSON: #"{"agent":"claude","prompt":"Review PR 7","title":"⚙ Review · run #\#(run)"}"#,
                status: "waiting"
            )
            return Request(workbench: p, run: run, step: step)
        }
    }

    /// A step of a run waiting on session `sessionID` (attached already).
    private func attachedStep(finished: Bool = false, failed: Bool = false) async throws -> (step: Int64, session: Int64) {
        try await pool.write { db in
            let p = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let a = try TestDatabase.insertAutomation(db, slug: "review-\(UUID().uuidString.prefix(6))", workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "session")
            let s = try TerminalSessionQueries.create(db, .init(
                projectID: p, kind: .claude, title: "s", folderPath: "/tmp/acme",
                claudeSessionID: UUID().uuidString.lowercased(), automationRunID: run
            ))
            if finished {
                try db.execute(sql: "UPDATE terminal_sessions SET finished_at = '2026-10-01T10:00:00Z' WHERE id = ?",
                               arguments: [s.id])
            }
            if failed {
                try db.execute(sql: "UPDATE terminal_sessions SET agent_failed_at = '2026-10-01T10:00:00Z' WHERE id = ?",
                               arguments: [s.id])
            }
            let step = try TestDatabase.insertAutomationStep(db, runID: run, seq: 1, kind: "session",
                                                             argsJSON: #"{"agent":"claude","prompt":"p","title":"t"}"#,
                                                             status: "waiting", sessionID: s.id)
            return (step, s.id)
        }
    }

    private func launched(_ step: Int64, _ session: Int64) -> [String] {
        ["automations", "session-launched", "--step", String(step), "--session", String(session), "--json"]
    }

    private func stopped(_ step: Int64) -> [String] {
        ["automations", "session-ended", "--step", String(step), "--status", "stopped", "--json"]
    }

    private func sessions(run: Int64) async throws -> [TerminalSession] {
        try await pool.read { db in
            try TerminalSession.fetchAll(db, sql: "SELECT * FROM terminal_sessions WHERE automation_run_id = ?",
                                         arguments: [run])
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not met in time")
    }

    // MARK: - Launch

    func testLaunchOnRequestWritesSessionIDAndWakes() async throws {
        let r = try await request()
        let center = makeCenter()

        await center.tick()

        XCTAssertEqual(starter.calls.map(\.stepID), [r.step])
        XCTAssertEqual(starter.calls.first?.prompt, "Review PR 7")
        let rows = try await sessions(run: r.run)
        let row = try XCTUnwrap(rows.first)
        // The CLI attaches the row and wakes the daemon (SIGUSR2).
        XCTAssertEqual(go.invocations, [launched(r.step, row.id)])
        XCTAssertTrue(center.launching.isEmpty)
        XCTAssertNil(center.lastError)
    }

    func testOneLaunchPerRequestUnderRepeatedPolls() async throws {
        let r = try await request()
        let gate = AsyncGate()
        starter.gate = gate
        let center = makeCenter()

        let first = Task { await center.tick() }
        await waitUntil { self.starter.calls.count == 1 }
        XCTAssertEqual(center.launching, [r.step])
        await center.tick()
        await center.tick()
        gate.release()
        await first.value

        XCTAssertEqual(starter.calls.count, 1)
        XCTAssertEqual(go.invocations.filter { $0[1] == "session-launched" }.count, 1)
        XCTAssertTrue(center.launching.isEmpty)
        // Attached: a later poll has nothing to do.
        await center.tick()
        XCTAssertEqual(starter.calls.count, 1)
        XCTAssertEqual(go.invocations.count, 1)
    }

    func testCrashBetweenCreateAndAttachAdoptsTheRow() async throws {
        let r = try await request()
        let orphan = try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: r.workbench, kind: .claude, title: "⚙ Review", folderPath: "/tmp/acme",
                claudeSessionID: UUID().uuidString.lowercased(), automationRunID: r.run
            ))
        }
        starter.live = [orphan.id]
        let center = makeCenter()

        await center.tick()

        XCTAssertTrue(starter.calls.isEmpty)
        XCTAssertEqual(go.invocations, [launched(r.step, orphan.id)])
    }

    /// An adopted row whose process is gone (the app crashed and came back)
    /// is attached and reported stopped at once: nothing would report it.
    func testAdoptedDeadRowIsReportedStopped() async throws {
        let r = try await request()
        let orphan = try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: r.workbench, kind: .claude, title: "⚙ Review", folderPath: "/tmp/acme",
                claudeSessionID: UUID().uuidString.lowercased(), automationRunID: r.run
            ))
        }
        let center = makeCenter()

        await center.tick()

        XCTAssertTrue(starter.calls.isEmpty)
        XCTAssertEqual(go.invocations, [launched(r.step, orphan.id), stopped(r.step)])
    }

    func testAppLaunchedLaterPicksPendingRequest() async throws {
        let r = try await request()
        let center = makeCenter()

        center.start()
        await waitUntil { self.pacer.sleeps >= 1 }
        center.stop()

        XCTAssertEqual(starter.calls.map(\.stepID), [r.step])
        XCTAssertEqual(go.invocations.first?[1], "session-launched")
    }

    func testLaunchFailureReportsLaunchFailed() async throws {
        let r = try await request()
        starter.failure = "Codex was not found"
        let center = makeCenter()

        await center.tick()

        XCTAssertEqual(go.invocations, [[
            "automations", "session-ended", "--step", String(r.step), "--status", "launch_failed",
            "--error", "Codex was not found", "--json"
        ]])
    }

    /// The refused launch's row stays in SESSIONS, but it is no longer the
    /// run's: a report that did not go through is retried, never turned
    /// into an adoption, and the run's next `session()` launches anew.
    func testRefusedLaunchIsReportedOnceAndNeverAdopted() async throws {
        let r = try await request()
        starter.failure = "Codex was not found"
        go.failEnds(1)
        let center = makeCenter()

        await center.tick()
        XCTAssertNotNil(center.lastError)
        await center.tick()
        await center.tick()

        XCTAssertEqual(starter.calls.count, 1)
        let calls = go.invocations
        XCTAssertEqual(calls.map { $0[1] }, ["session-ended", "session-ended"], "retried, then done: \(calls)")
        XCTAssertTrue(calls.allSatisfy { $0.contains("launch_failed") })
        XCTAssertNil(center.lastError)
        let runRows = try await sessions(run: r.run)
        XCTAssertTrue(runRows.isEmpty, "the refused row is no longer the run's")
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: r.workbench) }
        XCTAssertEqual(rows.count, 1, "the row itself stays")

        // The run's next session() step gets a session of its own.
        starter.failure = nil
        let next = try await pool.write { db in
            try TestDatabase.insertAutomationStep(db, runID: r.run, seq: 2, kind: "session",
                                                  argsJSON: #"{"agent":"claude","prompt":"again","title":"t"}"#,
                                                  status: "waiting")
        }
        await center.tick()
        XCTAssertEqual(starter.calls.map(\.stepID), [r.step, next])
        let freshRows = try await sessions(run: r.run)
        let fresh = try XCTUnwrap(freshRows.first)
        XCTAssertEqual(go.invocations.last, launched(next, fresh.id))
    }

    func testAttachRefusedLeavesSessionAlone() async throws {
        let r = try await request()
        go.refuseAttach()
        let center = makeCenter()

        await center.tick()
        await center.tick()

        XCTAssertEqual(starter.calls.count, 1, "no second launch")
        XCTAssertEqual(go.invocations.count, 1, "no second attach: \(go.invocations)")
        let runRows = try await sessions(run: r.run)
        XCTAssertEqual(runRows.count, 1, "the session is left as is")
    }

    /// A step whose args cannot be read is logged once, not on every poll.
    func testUnreadableStepIsLoggedOnce() async throws {
        let step = try await pool.write { db -> Int64 in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            return try TestDatabase.insertAutomationStep(db, runID: run, seq: 1, kind: "session", argsJSON: "not json",
                                                         status: "waiting")
        }
        let center = makeCenter()
        var logged: [Int64] = []
        center.logUnreadable = { logged.append($0) }

        await center.tick()
        await center.tick()

        XCTAssertEqual(logged, [step])
        XCTAssertTrue(starter.calls.isEmpty)
    }

    // MARK: - Stopped

    func testExitWhileWaitingReportsStopped() async throws {
        let (step, session) = try await attachedStep()
        starter.live = [session]
        let center = makeCenter()
        center.start()
        await waitUntil { self.pacer.sleeps >= 1 }
        XCTAssertTrue(go.invocations.isEmpty, "a live session is not reconciled")

        starter.live = []
        await center.sessionExited(rowID: session)

        XCTAssertEqual(go.invocations, [stopped(step)])
    }

    func testExitAfterFinishReportsNothing() async throws {
        let (_, finished) = try await attachedStep(finished: true)
        let (_, failed) = try await attachedStep(failed: true)
        starter.live = [finished, failed]
        let center = makeCenter()
        center.start()
        await waitUntil { self.pacer.sleeps >= 1 }

        starter.live = []
        await center.sessionExited(rowID: finished)
        await center.sessionExited(rowID: failed)

        XCTAssertTrue(go.invocations.isEmpty, "\(go.invocations)")
    }

    func testReconcileOnStartReportsStoppedForDeadSessions() async throws {
        let (dead, _) = try await attachedStep()
        let (_, alive) = try await attachedStep()
        starter.live = [alive]
        let center = makeCenter()

        center.start()
        await waitUntil { self.pacer.sleeps >= 1 }

        XCTAssertEqual(go.invocations, [stopped(dead)])
    }

    // MARK: - Feature off

    func testFeatureOffDoesNothing() async throws {
        let (_, session) = try await attachedStep()
        _ = try await request()
        let center = makeCenter()

        // Never started (the feature is off): an exit is left to the
        // reconcile of the next start.
        await center.sessionExited(rowID: session)
        center.start()
        center.stop()
        await center.sessionExited(rowID: session)

        XCTAssertFalse(center.isRunning)
        XCTAssertTrue(starter.calls.isEmpty)
        XCTAssertTrue(go.invocations.isEmpty, "\(go.invocations)")
    }

    func testAppStateRunsTheCenterOnlyWhileTheFeatureIsOn() async throws {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession(pid: 0) }
        appState.featureVisibility.disabledFeatureIDs = ["automations"]
        appState.initWorkbenches(dbPool: pool, cliRunner: go, notifier: RecordingWorkbenchNotifier(),
                                 sessionNotifier: RecordingSessionNotifier())
        defer { stopWorkbenchWiring(appState) }
        let center = try XCTUnwrap(appState.automationSessionCenter)
        XCTAssertFalse(center.isRunning)

        appState.featureVisibility.disabledFeatureIDs = []
        appState.syncAutomationSessionCenter()
        XCTAssertTrue(center.isRunning)

        appState.featureVisibility.disabledFeatureIDs = ["automations"]
        appState.syncAutomationSessionCenter()
        XCTAssertFalse(center.isRunning)
    }

    // MARK: - Navigation

    private func stopWorkbenchWiring(_ appState: AppState) {
        appState.automationSessionCenter?.stop()
        appState.sessionReportCenter?.stop()
        appState.sessionAgentStateCenter?.stop()
        appState.workbenchNotificationCenter?.stop()
        appState.workbenchesViewModel?.asks.stop()
        appState.ownerPresenceCenter?.stop()
    }

    /// Started → the owner leaves the Workbench page mid-launch → comes
    /// back: the AppState-owned center attaches the session it launched.
    func testRequestSurvivesNavigation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt asc \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let p = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let r = try await request(workbench: p)
        let gate = go.holdAttach()
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession(pid: 0) }
        appState.terminalCenter.shell = { "/bin/zsh" }
        appState.selectedDestination = .workbench
        appState.initWorkbenches(dbPool: pool, cliRunner: go, notifier: RecordingWorkbenchNotifier(),
                                 sessionNotifier: RecordingSessionNotifier())
        defer { stopWorkbenchWiring(appState) }
        let center = try XCTUnwrap(appState.automationSessionCenter)
        XCTAssertTrue(center.isRunning, "started with the Workbench wiring, the feature on")

        await waitUntil { self.go.invocations.contains { $0[1] == "session-launched" } }
        XCTAssertEqual(center.launching, [r.step])
        appState.selectedDestination = .inbox
        appState.selectedDestination = .workbench
        gate.release()

        await waitUntil { center.launching.isEmpty }
        XCTAssertTrue(appState.automationSessionCenter === center, "the same AppState-owned center")
        let attached = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT session_id FROM automation_run_steps WHERE id = ?", arguments: [r.step])
        }
        let rows = try await sessions(run: r.run)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(attached, row.id)
        XCTAssertEqual(appState.terminalCenter.states[row.id], .running)
    }
}
