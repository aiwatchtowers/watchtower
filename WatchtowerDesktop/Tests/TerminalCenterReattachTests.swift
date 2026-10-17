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
        XCTAssertTrue(center.unprotected.isEmpty, "an adopted run lives in the host")
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

    /// The host listed one row twice: the newest run is adopted, the other stopped.
    func testReattachAdoptsTheNewestOfSeveralRuns() async throws {
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
        XCTAssertEqual(signals.map(\.0), [7001])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-old")])
        await hosted.connecting?.value
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

    /// A hosted run of a row that already runs locally is a second agent
    /// on the row: stopped, and the local run kept.
    func testHostedRunOfALocallyRunningRowIsStopped() async throws {
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
        XCTAssertEqual(signals.map(\.0), [7200])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertEqual(try forgotten(), [SessionHostAttachRequest(row: row.id, run: "run-h")])
        XCTAssertEqual(transports.count, 1, "nothing attached")
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
}
