import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Reattach at launch (board #496): the runs the session host still holds
/// are adopted, stopped or reported against the rows that still exist —
/// never relaunched. No real host and no real signals: the host is a fake
/// transport, the process groups a recording signaller.
@MainActor
final class TerminalCenterReattachTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var transports: [FakeSessionHostTransport] = []
    private var signals: [(pid_t, Int32)] = []
    /// Pids the signaller reports alive; one in `diesOnHangup` leaves on SIGHUP.
    private var alive: Set<pid_t> = []
    private var diesOnHangup: Set<pid_t> = []
    private var slept: Duration = .zero
    private var factoryCalls = 0
    private var exits: [(Int64, Int32?, Bool)] = []
    private var center: TerminalCenter!
    private var vm: WorkbenchesViewModel!

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "TerminalCenterReattachTests-\(UUID().uuidString)"))
        transports = []
        signals = []
        alive = []
        diesOnHangup = []
        slept = .zero
        factoryCalls = 0
        exits = []
        center = TerminalCenter(
            makeProcess: { [weak self] in
                self?.factoryCalls += 1
                return FakeTerminalSession()
            },
            signaller: ProcessGroupSignaller(
                signal: { [weak self] pid, sig in
                    guard let self else { return }
                    signals.append((pid, sig))
                    if sig == SIGKILL || (sig == SIGHUP && diesOnHangup.contains(pid)) { alive.remove(pid) }
                },
                isAlive: { [weak self] pid in self?.alive.contains(pid) ?? false },
                sleep: { [weak self] step in self?.slept += step }
            )
        )
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        let client = SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { [weak self] _ in
            let transport = FakeSessionHostTransport()
            self?.transports.append(transport)
            return transport
        })
        client.signalGroup = { _, _ in XCTFail("reattach signals through the center's signaller") }
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        center.sessionHost = client
        vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                  terminalCenter: center)
        let exitHandler = center.onSessionExit
        center.onSessionExit = { [weak self] id, code, closedByApp in
            self?.exits.append((id, code, closedByApp))
            exitHandler?(id, code, closedByApp)
        }
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    /// The host's control connection: the first one the client opened.
    private var control: FakeSessionHostTransport { transports[0] }

    private func sessionRow() async throws -> TerminalSession {
        let folder = FileManager.default.temporaryDirectory.path
        return try await pool.write { db in
            let projectID = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            return try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "s", folderPath: folder,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    private func forgotten() throws -> [SessionHostAttachRequest] {
        try control.sent(.forget).map { try $0.decoded(SessionHostAttachRequest.self) }
    }

    private func launchesSent() -> Int {
        transports.reduce(0) { $0 + $1.sent(.launch).count }
    }

    func testProj20_ReattachAdoptsRunningSessionWithoutRelaunch() async throws {
        let row = try await sessionRow()
        let info = SessionHostSessionInfo(row: row.id, run: "run-a", pid: 5150, startedAtMs: 1_760_000_000_250,
                                          exited: false, code: nil)
        control.listed = [info]

        await vm.reattachHostedSessions()

        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(center.liveIDs, [row.id])
        XCTAssertEqual(center.startedAt[row.id], Date(timeIntervalSince1970: 1_760_000_000.25),
                       "the run's start is the host's, not the adoption's")
        XCTAssertEqual(factoryCalls, 0, "adoption builds no launch process")
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertEqual(hosted.pid, 5150)
        await hosted.connecting?.value
        XCTAssertEqual(transports.count, 2, "one session connection beside the control one")
        let session = try XCTUnwrap(transports.last)
        XCTAssertEqual(session.sent.map(\.type), [.hello, .attach])
        XCTAssertEqual(try session.sent(.attach).first?.decoded(SessionHostAttachRequest.self),
                       SessionHostAttachRequest(row: row.id, run: "run-a"))
        XCTAssertEqual(launchesSent(), 0)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(try forgotten().isEmpty)
        XCTAssertTrue(exits.isEmpty)

        // A second reattach (the workbench state rebuilt) finds the run held.
        await vm.reattachHostedSessions()
        XCTAssertTrue(center.process(for: row.id) === hosted)
        XCTAssertEqual(transports.count, 2, "no second attach")

        // Opening the row afterwards does not relaunch it (no `--resume`).
        await vm.open(row)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(launchesSent(), 0)
        XCTAssertTrue(center.process(for: row.id) === hosted)
        XCTAssertNil(vm.resumeStarts[row.id])
        XCTAssertEqual(center.states[row.id], .running)

        hosted.detachFromHost()
    }

    /// A7b: a run a newer version left in the shared host for a kind this
    /// build does not know is adopted (never stopped) and counts as a live
    /// agent for the branch switch's guard (PROJ-10): it may be an agent.
    func testAnAdoptedRunOfAnUnknownKindCountsAsALiveAgent() async throws {
        let folder = FileManager.default.temporaryDirectory.path
        let row = try await pool.write { db -> TerminalSession in
            let projectID = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: """
                INSERT INTO terminal_sessions (project_id, kind, title, title_source, folder_path, created_at, last_active_at)
                VALUES (?, 'gemini', 'Newer', 'auto', ?, '2026-11-08T10:00:00Z', '2026-11-08T10:00:00Z')
                """,
                arguments: [projectID, folder]
            )
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
            return try XCTUnwrap(TerminalSessionQueries.fetchForWorkbench(db, projectID: projectID).first)
        }
        XCTAssertEqual(row.kind, .unsupported("gemini"))
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-g", pid: 5151, startedAtMs: 1_760_000_000_000,
                                                 exited: false, code: nil)]

        await vm.reattachHostedSessions()

        XCTAssertEqual(center.states[row.id], .running, "the run is the newer version's work: never stopped")
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(center.hasLiveAgentSession(workbenchID: try XCTUnwrap(row.projectID), workTree: "/tmp/elsewhere"))
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        await hosted.connecting?.value

        // Opening the adopted row is not refused as unsupported: the held
        // run stays on screen, nothing is launched in its place. The newer
        // version's migration widened the `kind` CHECK, so the open's own
        // update of the row (`touch`) passes: the check stays off on the writer.
        try await pool.write { try $0.execute(sql: "PRAGMA ignore_check_constraints = ON") }
        await vm.open(row)
        XCTAssertNil(vm.sessionActionErrors[row.projectID], "opened, not refused")
        let shown = vm.layout(projectID: try XCTUnwrap(row.projectID)).visiblePanes
        XCTAssertTrue(shown.contains { WorkspaceLayout.sessionID(of: $0) == row.id }, "the held run is put on screen")
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertTrue(center.process(for: row.id) === hosted)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(launchesSent(), 0)
        hosted.detachFromHost()
    }

    /// The launch order: the reattach waits for the host connection begun
    /// before it, and an `activate` meanwhile waits for the reattach.
    func testStartHostReattachWaitsForTheConnection() async throws {
        let row = try await sessionRow()
        let info = SessionHostSessionInfo(row: row.id, run: "run-d", pid: 5153, startedAtMs: 1, exited: false, code: nil)
        var opened: [FakeSessionHostTransport] = []
        center.sessionHost = nil
        center.startSessionHost {
            SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { _ in
                let transport = FakeSessionHostTransport()
                transport.listed = [info]
                opened.append(transport)
                return transport
            })
        }
        XCTAssertFalse(center.hostRunsSettled)
        vm.startHostReattach()
        await vm.open(row)
        await vm.hostReattach?.value
        XCTAssertTrue(center.hostRunsSettled, "#517: the phone's permission expiry may judge liveness now")
        XCTAssertNotNil(center.sessionHost)
        XCTAssertEqual(center.states[row.id], .running)
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertEqual(hosted.key, SessionHostAttachRequest(row: row.id, run: "run-d"), "adopted, not launched")
        XCTAssertEqual(factoryCalls, 0)
        await hosted.connecting?.value
        XCTAssertEqual(opened.reduce(0) { $0 + $1.sent(.launch).count }, 0)
        hosted.detachFromHost()
    }

    func testReattachStopsSessionWhoseRowIsGone() async throws {
        alive = [6000, 6001]
        diesOnHangup = [6001]
        control.listed = [
            SessionHostSessionInfo(row: 9001, run: "run-x", pid: 6000, startedAtMs: 1, exited: false, code: nil),
            SessionHostSessionInfo(row: 9002, run: "run-y", pid: 6001, startedAtMs: 1, exited: false, code: nil)
        ]

        await vm.reattachHostedSessions()
        await center.strayStops?.value

        let stubborn = signals.filter { $0.0 == 6000 }.map(\.1)
        XCTAssertEqual(stubborn, [SIGHUP, SIGKILL], "alive after the grace: killed")
        XCTAssertGreaterThanOrEqual(slept, TerminalCenter.killGrace)
        XCTAssertEqual(signals.filter { $0.0 == 6001 }.map(\.1), [SIGHUP], "gone on the hang-up: no kill")
        XCTAssertEqual(try forgotten().sorted { $0.row < $1.row }, [
            SessionHostAttachRequest(row: 9001, run: "run-x"),
            SessionHostAttachRequest(row: 9002, run: "run-y")
        ])
        XCTAssertTrue(center.states.isEmpty)
        XCTAssertNil(center.process(for: 9001))
        XCTAssertEqual(transports.count, 1, "nothing attached")
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertTrue(exits.isEmpty)
    }

    /// Row ids are per workspace database: a run another workspace
    /// launched is never stopped, adopted, forgotten or reported here.
    func testReattachIgnoresAnotherWorkspacesRuns() async throws {
        let row = try await sessionRow()
        center.sessionHostScope = "ws-a"
        alive = [6100, 6101]
        control.listed = [
            SessionHostSessionInfo(row: 9001, run: "run-o", pid: 6100, startedAtMs: 1, exited: false, code: nil, scope: "ws-b"),
            SessionHostSessionInfo(row: row.id, run: "run-p", pid: 6101, startedAtMs: 1, exited: false, code: nil, scope: "ws-b"),
            SessionHostSessionInfo(row: row.id, run: "run-q", pid: 6102, startedAtMs: 1, exited: true, code: 0, scope: "ws-b")
        ]

        await vm.reattachHostedSessions()
        await center.strayStops?.value

        XCTAssertTrue(signals.isEmpty, "another workspace's agents are not stopped")
        XCTAssertNil(center.strayStops)
        XCTAssertNil(center.states[row.id], "a colliding row id is not adopted")
        XCTAssertNil(center.process(for: row.id))
        XCTAssertTrue(try forgotten().isEmpty)
        XCTAssertTrue(exits.isEmpty)
        XCTAssertEqual(transports.count, 1, "nothing attached")
    }

    /// #1086: the host listed one live row twice (a Restart launched a
    /// second agent beside one the pane had lost): the newest run is
    /// adopted and the older one — maybe an agent still at work — is never
    /// signalled by the reattach: it is kept as the row's other run, live,
    /// and the pane's Stop stops it alone.
    func testReattachAdoptsTheNewestOfSeveralRunsAndLeavesTheOlderRunning() async throws {
        let row = try await sessionRow()
        center.sessionHostScope = "ws-a"
        alive = [7001, 7002]
        diesOnHangup = [7001]
        control.listed = [
            SessionHostSessionInfo(row: row.id, run: "run-old", pid: 7001, startedAtMs: 1, exited: false, code: nil, scope: "ws-a"),
            SessionHostSessionInfo(row: row.id, run: "run-new", pid: 7002, startedAtMs: 2, exited: false, code: nil, scope: "ws-a")
        ]

        await vm.reattachHostedSessions()
        await center.strayStops?.value

        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertEqual(hosted.key, SessionHostAttachRequest(row: row.id, run: "run-new"))
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertNil(center.strayStops, "nothing to stop")
        XCTAssertTrue(signals.isEmpty, "the older run is not signalled")
        XCTAssertTrue(try forgotten().isEmpty, "nor forgotten")
        XCTAssertEqual(center.extraHostRuns[row.id]?.map(\.run), ["run-old"])
        XCTAssertTrue(center.liveIDs.contains(row.id))
        await hosted.connecting?.value

        // The pane's Stop: the other run only, by its pid as listed now.
        let failure = await center.stopLiveHostRuns(of: row.id)
        XCTAssertNil(failure)
        XCTAssertEqual(signals.map(\.0), [7001])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-old")])
        XCTAssertNil(center.extraHostRuns[row.id])
        XCTAssertEqual(center.states[row.id], .running, "the shown run goes on")
        hosted.detachFromHost()
    }

    /// An old exited run beside the running one: only forgotten, never reported.
    func testExitedRunIsNotReportedBesideARunningOne() async throws {
        let row = try await sessionRow()
        control.listed = [
            SessionHostSessionInfo(row: row.id, run: "run-done", pid: 7101, startedAtMs: 1, exited: true, code: 1),
            SessionHostSessionInfo(row: row.id, run: "run-live", pid: 7102, startedAtMs: 2, exited: false, code: nil)
        ]

        await vm.reattachHostedSessions()

        XCTAssertTrue(exits.isEmpty)
        XCTAssertEqual(center.states[row.id], .running)
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertEqual(hosted.key, SessionHostAttachRequest(row: row.id, run: "run-live"))
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-done")])
        XCTAssertTrue(signals.isEmpty)
        await hosted.connecting?.value
        hosted.detachFromHost()
    }

    /// A hosted run of a row that already runs here is not the one the row
    /// shows, but may be an agent at work (#1086): never signalled by the
    /// reattach, kept as the row's other run; a close of the row stops it.
    func testHostedRunOfARowRunningHereIsLeftRunning() async throws {
        let row = try await sessionRow()
        center.start(row, fresh: false)
        let local = try XCTUnwrap(center.process(for: row.id) as? FakeTerminalSession)
        alive = [7200]
        diesOnHangup = [7200]
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-h", pid: 7200, startedAtMs: 1, exited: false, code: nil)]

        await vm.reattachHostedSessions()
        await center.strayStops?.value

        XCTAssertTrue(center.process(for: row.id) === local)
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(try forgotten().isEmpty)
        XCTAssertEqual(transports.count, 1, "nothing attached")
        XCTAssertEqual(center.extraHostRuns[row.id]?.map(\.run), ["run-h"])

        await center.closeAll()

        XCTAssertTrue(signals.contains { $0 == (7200, SIGHUP) }, "Stop Sessions stops the other run too")
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-h")])
        XCTAssertTrue(center.extraHostRuns.isEmpty)
    }

    /// An update's quit keeps a row's other run running, like the shown one.
    func testDetachAllLeavesTheOtherRunRunning() async throws {
        let row = try await sessionRow()
        control.listed = [
            SessionHostSessionInfo(row: row.id, run: "run-old", pid: 7210, startedAtMs: 1, exited: false, code: nil),
            SessionHostSessionInfo(row: row.id, run: "run-new", pid: 7211, startedAtMs: 2, exited: false, code: nil)
        ]
        await vm.reattachHostedSessions()
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        await hosted.connecting?.value

        await center.detachAll()

        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(try forgotten().isEmpty)
        XCTAssertTrue(center.extraHostRuns.isEmpty)
        XCTAssertTrue(control.sent(.stop).isEmpty)
    }

    /// Adoption replaces a row's ended local process, detaching its view.
    func testAdoptionDetachesAnEndedLocalProcess() async throws {
        let row = try await sessionRow()
        center.start(row, fresh: false)
        let local = try XCTUnwrap(center.process(for: row.id) as? FakeTerminalSession)
        local.exit(0)
        exits = []
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-l", pid: 7300, startedAtMs: 1, exited: false, code: nil)]

        await vm.reattachHostedSessions()

        XCTAssertTrue(local.detached)
        XCTAssertNil(local.onExit)
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertEqual(center.states[row.id], .running)
        await hosted.connecting?.value
        hosted.detachFromHost()
    }

    /// A run that ended while the app was away is attached, so the pane
    /// shows its last output; its exit is reported once, as a natural one,
    /// and forgotten by its session.
    func testReattachReportsExitOnceAndForgets() async throws {
        let row = try await sessionRow()
        let info = SessionHostSessionInfo(row: row.id, run: "run-b", pid: 5151, startedAtMs: 1, exited: true, code: 0)
        control.listed = [info]

        await vm.reattachHostedSessions()

        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        await hosted.connecting?.value
        XCTAssertEqual(transports.count, 2, "the exited run is attached for its last output")
        let session = try XCTUnwrap(transports.last)
        XCTAssertEqual(try session.sent(.attach).first?.decoded(SessionHostAttachRequest.self),
                       SessionHostAttachRequest(row: row.id, run: "run-b"))
        XCTAssertTrue(try forgotten().isEmpty, "the session forgets it after the exit")
        session.push(.json(.attached, info))
        session.push(SessionHostFrame(type: .output, payload: Array("last words".utf8)))
        session.push(.json(.exit, SessionHostExit(code: 0)))
        let view = try XCTUnwrap(hosted.view as? PalettedTerminalView)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "last words")

        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first?.0, row.id)
        XCTAssertEqual(exits.first?.1, 0)
        XCTAssertEqual(exits.first?.2, false, "an exit while the app was away is a natural exit")
        XCTAssertEqual(center.states[row.id], .exited(0))
        for _ in 0..<200 where control.sent(.forget).isEmpty { await Task.yield() }
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-b")])
        XCTAssertTrue(signals.isEmpty)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(launchesSent(), 0)

        control.listed = []
        await vm.reattachHostedSessions()
        XCTAssertEqual(exits.count, 1, "reported once")
        XCTAssertEqual(try forgotten().count, 1)
    }

    /// The host refuses a forget while it has not reaped a killed child
    /// yet: the stray's forget is asked once more.
    func testStrayForgetIsRetriedOnceWhenRefused() async throws {
        alive = [6200]
        diesOnHangup = [6200]
        control.refusedForgets = 1
        control.listed = [SessionHostSessionInfo(row: 9003, run: "run-z", pid: 6200, startedAtMs: 1, exited: false, code: nil)]

        await vm.reattachHostedSessions()
        await center.strayStops?.value

        XCTAssertEqual(try forgotten(), [
            SessionHostAttachRequest(row: 9003, run: "run-z"),
            SessionHostAttachRequest(row: 9003, run: "run-z")
        ])
        XCTAssertEqual(control.refusedForgets, 0)
    }

    func testReattachIgnoresListFailure() async throws {
        let row = try await sessionRow()
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-c", pid: 5152, startedAtMs: 1, exited: false, code: nil)]
        control.autoReply = false

        let reattach = Task { await vm.reattachHostedSessions() }
        for _ in 0..<200 where control.sent(.list).isEmpty { await Task.yield() }
        XCTAssertEqual(control.sent(.list).count, 1)
        control.push(.json(.error, SessionHostErrorMessage(message: "boom")))
        await reattach.value

        XCTAssertNil(center.states[row.id], "the row reads as stopped")
        XCTAssertNil(center.process(for: row.id))
        XCTAssertTrue(center.liveIDs.isEmpty)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(control.sent(.forget).isEmpty)
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(factoryCalls, 0)
    }

    // MARK: #1086 — a lost connection is not an exit, Restart attaches

    /// A row whose last run reads as ended here (the pane lost it).
    private func endedRow() async throws -> TerminalSession {
        let row = try await sessionRow()
        center.start(row, fresh: false)
        try XCTUnwrap(center.process(for: row.id) as? FakeTerminalSession).exit(nil)
        XCTAssertEqual(center.states[row.id], .exited(nil))
        XCTAssertEqual(factoryCalls, 1)
        return row
    }

    /// Restart while the host still runs the row's agent attaches to it:
    /// no launch, no `--resume`, no second agent on the transcript.
    func testRestartAttachesToALiveRunInsteadOfLaunching() async throws {
        let row = try await endedRow()
        control.listed = [
            SessionHostSessionInfo(row: row.id, run: "run-old", pid: 7400, startedAtMs: 1, exited: false, code: nil),
            SessionHostSessionInfo(row: row.id, run: "run-live", pid: 7401, startedAtMs: 2, exited: false, code: nil),
            SessionHostSessionInfo(row: row.id, run: "run-done", pid: 7402, startedAtMs: 3, exited: true, code: 0),
            SessionHostSessionInfo(row: row.id, run: "run-other", pid: 7403, startedAtMs: 4, exited: false, code: nil,
                                   scope: "another-workspace")
        ]

        await vm.open(row, placement: .inPlace)

        XCTAssertEqual(factoryCalls, 1, "no launch process")
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertEqual(hosted.key, SessionHostAttachRequest(row: row.id, run: "run-live"))
        XCTAssertEqual(center.states[row.id], .running)
        await hosted.connecting?.value
        XCTAssertEqual(launchesSent(), 0)
        XCTAssertNil(vm.resumeStarts[row.id])
        XCTAssertTrue(signals.isEmpty)
        hosted.detachFromHost()
    }

    /// Restart with no live run of the row in the host launches as before.
    func testRestartWithoutALiveRunLaunches() async throws {
        let row = try await endedRow()
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-done", pid: 7410, startedAtMs: 1, exited: true, code: 0)]

        await vm.open(row, placement: .inPlace)

        let local = try XCTUnwrap(center.process(for: row.id) as? FakeTerminalSession)
        XCTAssertEqual(local.launches.count, 2, "relaunched")
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(control.sent(.list).count, 1, "the host was asked first")
    }

    /// A host that cannot say whether the row still runs gets no launch:
    /// the error is shown and nothing starts beside a live agent.
    func testRestartWhenTheHostCannotListLaunchesNothing() async throws {
        let row = try await endedRow()
        control.failedLists = 1

        await vm.open(row, placement: .inPlace)

        XCTAssertEqual(factoryCalls, 1, "nothing launched")
        XCTAssertEqual(center.states[row.id], .exited(nil))
        let error = try XCTUnwrap(vm.sessionActionErrors[row.projectID])
        XCTAssertTrue(error.contains("Could not ask the session host"), error)
    }

    /// A lost connection of an adopted run shows as disconnected on a
    /// running row — never an exit — and the owner's Reconnect reattaches.
    func testADisconnectedRunStaysRunningAndReconnects() async throws {
        let row = try await sessionRow()
        let info = SessionHostSessionInfo(row: row.id, run: "run-r", pid: 7500, startedAtMs: 1, exited: false, code: nil)
        control.listed = [info]
        await vm.reattachHostedSessions()
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        HostedSessionTestClock().drive(hosted)
        await hosted.connecting?.value
        try XCTUnwrap(transports.last).push(.json(.attached, info))
        XCTAssertNil(center.hostLinks[row.id])

        control.failedLists = 1000
        try XCTUnwrap(transports.last).hangUp()
        await hosted.settled()

        XCTAssertEqual(center.states[row.id], .running, "the host may still run it")
        XCTAssertEqual(center.hostLinks[row.id], .lost(SessionHostError.host("list failed").localizedDescription))
        XCTAssertTrue(exits.isEmpty)

        control.failedLists = 0
        center.reconnect(sessionID: row.id)
        XCTAssertEqual(center.hostLinks[row.id], .reconnecting)
        await hosted.settled()
        try XCTUnwrap(transports.last).push(.json(.attached, info))
        XCTAssertNil(center.hostLinks[row.id])
        XCTAssertTrue(exits.isEmpty)
        XCTAssertEqual(launchesSent(), 0)
        hosted.detachFromHost()
    }

    // MARK: #1086 round 1 — closing a disconnected run, other runs, gates

    /// A run adopted and attached (launch 1), driven by a test clock.
    private func attachedRun(_ row: TerminalSession, run: String = "run-r", pid: Int = 7600) async throws
        -> (HostedTerminalSession, SessionHostSessionInfo) {
        let info = SessionHostSessionInfo(row: row.id, run: run, pid: pid, startedAtMs: 1, exited: false, code: nil, launch: 1)
        control.listed = [info]
        await vm.reattachHostedSessions()
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        HostedSessionTestClock().drive(hosted)
        await hosted.connecting?.value
        try XCTUnwrap(transports.last).push(.json(.attached, info))
        return (hosted, info)
    }

    /// Closing a session that lost its host connection stops the run with
    /// the host's Stop (its run and launch), ends the reconnects and
    /// forgets the run; no stale pid is signalled.
    func testClosingADisconnectedRunStopsItThroughTheHostAndForgetsIt() async throws {
        let row = try await sessionRow()
        let (hosted, info) = try await attachedRun(row)
        control.failedLists = 1000
        try XCTUnwrap(transports.last).hangUp()
        await hosted.settled()
        XCTAssertNotNil(center.hostLinks[row.id])

        control.failedLists = 0
        control.listed = [SessionHostSessionInfo(row: row.id, run: info.run, pid: info.pid, startedAtMs: 1, exited: true, code: nil)]
        await center.close(sessionID: row.id)
        await hosted.settled()
        let lists = control.sent(.list).count
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(try control.sent(.stop).map { try $0.decoded(SessionHostStopRequest.self) },
                       [SessionHostStopRequest(row: row.id, run: info.run, launch: 1)])
        XCTAssertEqual(control.sent(.list).count, lists, "no reconnect after the close")
        XCTAssertNil(center.hostLinks[row.id])
        XCTAssertNil(center.states[row.id])
        XCTAssertTrue(signals.isEmpty, "the host stopped it: no signal from here")
        XCTAssertTrue(try forgotten().contains(SessionHostAttachRequest(row: row.id, run: info.run)))
        XCTAssertTrue(exits.allSatisfy { $0.2 }, "the owner's close is never a natural exit")
    }

    /// Stop Sessions while a run reconnects: the host's Stop goes out, so
    /// even when the run could not be forgotten, the next launch's reattach
    /// reads its exit as the owner's (`requested`), not a natural one.
    func testClosingAllDuringAReconnectIsNeverANaturalExitLater() async throws {
        let row = try await sessionRow()
        let (hosted, info) = try await attachedRun(row)
        hosted.reconnectSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        control.failedLists = 1000
        try XCTUnwrap(transports.last).hangUp()
        for _ in 0..<50 where control.sent(.list).isEmpty { await Task.yield() }
        XCTAssertEqual(center.hostLinks[row.id], .reconnecting)

        await center.closeAll()
        await hosted.settled()

        XCTAssertEqual(control.sent(.stop).count, 1)
        XCTAssertTrue(signals.isEmpty, "the host cannot vouch for the pid: nothing signalled")
        XCTAssertNil(center.hostLinks[row.id])
        XCTAssertTrue(exits.isEmpty)

        // The next launch: the host still holds the stopped run's record.
        control.failedLists = 0
        let ended = SessionHostSessionInfo(row: row.id, run: info.run, pid: info.pid, startedAtMs: 1, exited: true, code: 0)
        control.listed = [ended]
        await vm.reattachHostedSessions()
        let next = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        XCTAssertFalse(next === hosted)
        await next.connecting?.value
        let session = try XCTUnwrap(transports.last)
        session.push(.json(.attached, ended))
        session.push(.json(.exit, SessionHostExit(code: 0, requested: true)))
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first?.2, true, "a stopped run's exit is the owner's: no PROJ-18 cleanup")
    }

    /// An exit the host reports during an outage ends the disconnected
    /// state with the run.
    func testAnExitDuringAnOutageClearsTheDisconnectedBar() async throws {
        let row = try await sessionRow()
        let (hosted, info) = try await attachedRun(row)
        control.failedLists = 2
        control.listed = [SessionHostSessionInfo(row: row.id, run: info.run, pid: info.pid, startedAtMs: 1, exited: true, code: 3)]
        try XCTUnwrap(transports.last).hangUp()
        XCTAssertEqual(center.hostLinks[row.id], .reconnecting)
        await hosted.settled()

        XCTAssertEqual(center.states[row.id], .exited(3))
        XCTAssertNil(center.hostLinks[row.id])
        XCTAssertEqual(exits.map(\.1), [3])
    }

    /// Start fresh never runs beside a live run of the row the host holds:
    /// it is stopped first.
    func testStartFreshStopsALiveHostRunFirst() async throws {
        let row = try await endedRow()
        alive = [7700]
        diesOnHangup = [7700]
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-live", pid: 7700, startedAtMs: 1, exited: false, code: nil)]

        await vm.startFresh(row, placement: .inPlace)

        XCTAssertEqual(signals.map(\.0), [7700])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-live")])
        let local = try XCTUnwrap(center.process(for: row.id) as? FakeTerminalSession)
        XCTAssertEqual(local.launches.count, 1, "launched fresh after the stop")
        XCTAssertEqual(center.states[row.id], .running)
    }

    /// Start fresh with a host that cannot list starts nothing.
    func testStartFreshWhenTheHostCannotListStartsNothing() async throws {
        let row = try await endedRow()
        control.failedLists = 1

        await vm.startFresh(row, placement: .inPlace)

        XCTAssertNil(center.process(for: row.id), "the old process was closed and none launched")
        XCTAssertTrue(signals.isEmpty)
        let error = try XCTUnwrap(vm.sessionActionErrors[row.projectID])
        XCTAssertTrue(error.contains("so nothing was started"), error)
    }

    /// A client whose host does not answer (even one only slow) is no
    /// answer: nothing launches. With no client at all there is nothing to
    /// ask and the launch may go ahead.
    func testAHostThatDoesNotAnswerIsUnknownButNoClientIsNone() async throws {
        let row = try await sessionRow()
        let quiet = TerminalCenter(makeProcess: { FakeTerminalSession() }, signaller: ProcessGroupSignaller(
            signal: { _, _ in XCTFail("nothing is signalled") }, isAlive: { _ in false }, sleep: { _ in }
        ))
        let none = await quiet.adoptLiveHostRun(row)
        XCTAssertEqual(none, .none, "no client: nothing to ask")

        await quiet.connectSessionHost {
            SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { _ in
                let transport = FakeSessionHostTransport()
                transport.openError = CocoaError(.fileNoSuchFile)
                return transport
            })
        }
        let unknown = await quiet.adoptLiveHostRun(row)
        XCTAssertEqual(unknown, .unknown(HostedTerminalSession.hostNotRunningReason))
    }

    /// A background open (the phone's open_existing) whose host cannot say
    /// whether the row runs fails, though the row still reads as before.
    func testABackgroundOpenThatCannotAskTheHostFails() async throws {
        let folder = FileManager.default.temporaryDirectory.path
        let (row, target) = try await pool.write { db -> (TerminalSession, Int64) in
            let projectID = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: projectID, text: "Ship it")
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "s", targetID: target, folderPath: folder,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
            return (row, target)
        }
        center.start(row, fresh: false)
        try XCTUnwrap(center.process(for: row.id) as? FakeTerminalSession).exit(0)
        control.failedLists = 1

        do {
            _ = try await vm.startForTarget(targetID: target, prompt: nil, mode: .openExisting, placement: .background)
            XCTFail("expected a failure")
        } catch let error as WorkbenchesViewModel.TargetStartError {
            guard case let .failed(message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Could not ask the session host"), message)
        }
        XCTAssertEqual(center.states[row.id], .exited(0))
    }

    /// The adoption's focus goes only to the latest switch: a switch begun
    /// while the host was asked keeps the focus.
    func testARestartAdoptionFocusesOnlyTheLatestSwitch() async throws {
        let row = try await endedRow()
        let projectID = try XCTUnwrap(row.projectID)
        control.listed = [SessionHostSessionInfo(row: row.id, run: "run-live", pid: 7800, startedAtMs: 1, exited: false, code: nil)]
        control.autoReply = false
        let opening = Task { await vm.open(row, placement: .inPlace) }
        for _ in 0..<500 where control.sent(.list).isEmpty { await Task.yield() }
        XCTAssertEqual(control.sent(.list).count, 1)
        let focusedBefore = center.focusOrder
        _ = vm.beginSwitch(projectID: projectID)
        control.push(.json(.listed, SessionHostListResponse(sessions: control.listed)))
        await opening.value

        XCTAssertEqual(center.states[row.id], .running, "adopted")
        XCTAssertEqual(center.focusOrder, focusedBefore, "a later switch decides the focus")
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        await hosted.connecting?.value
        hosted.detachFromHost()
    }
}
