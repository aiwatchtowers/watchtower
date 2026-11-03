import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The one-time restart of sessions from a v1 session host (go hub spec §8
/// p. 4b steps 0–3 and Failures; asks #813, #814). No real host, no real
/// signals: the host is a fake transport (`v1Host` until the step's SIGTERM
/// replaces it), process groups and the old host's pid a recording
/// signaller, the restart list a temp file.
@MainActor
final class HostRestartStepTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var listDir: URL!
    private var listURL: URL!
    private var folder: URL!
    private var transports: [FakeSessionHostTransport] = []
    private var signals: [(pid_t, Int32)] = []
    private var alive: Set<pid_t> = []
    private var factoryCalls = 0
    private var launched: [FakeTerminalSession] = []
    private var exits: [(Int64, Int32?, Bool)] = []
    /// What the next connection reaches: a v1 host, a v2 one, or nothing.
    private var hostV1 = true
    private var hostUp = true
    /// The old host's answer to SIGTERM: true = it exits.
    private var hostExitsOnTerm = true
    private var hostSignals: [(pid_t, Int32)] = []
    /// Called on each SIGHUP to a session's group (an order probe).
    private var onHangup: ((pid_t) -> Void)?
    private var settledSeen = false
    /// Called for every new connection (the pid confirm's Hello is one).
    private var onNewTransport: (() -> Void)?
    private var center: TerminalCenter!
    private var client: SessionHostClient!
    private var vm: WorkbenchesViewModel!

    private let scope = "aaaa1111aaaa1111"
    private let otherScope = "bbbb2222bbbb2222"
    private static let oldHostPID: pid_t = 99

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "HostRestartStepTests-\(UUID().uuidString)"))
        listDir = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestartStepTests-\(UUID().uuidString)")
        listURL = listDir.appendingPathComponent(HostRestartList.fileName)
        folder = listDir.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        transports = []
        signals = []
        alive = []
        factoryCalls = 0
        launched = []
        exits = []
        hostV1 = true
        hostUp = true
        hostExitsOnTerm = true
        hostSignals = []
        onHangup = nil
        center = TerminalCenter(
            makeProcess: { [weak self] in
                self?.factoryCalls += 1
                let process = FakeTerminalSession()
                self?.launched.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { [weak self] pid, sig in
                    guard let self else { return }
                    signals.append((pid, sig))
                    if sig == SIGHUP { onHangup?(pid) }
                    if sig == SIGHUP || sig == SIGKILL { alive.remove(pid) }
                },
                isAlive: { [weak self] pid in self?.alive.contains(pid) ?? false },
                sleep: { _ in }
            )
        )
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        center.sessionHostScope = scope
        client = SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { [weak self] _ in
            let transport = FakeSessionHostTransport()
            if let self {
                transport.v1Host = hostV1
                if !hostUp { transport.openError = SessionHostError.disconnected }
                transports.append(transport)
                onNewTransport?()
            }
            return transport
        })
        client.sleep = { _ in }
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        XCTAssertFalse(client.speaksV2, "the update left a v1 host")
        center.sessionHost = client
        vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                  terminalCenter: center)
        vm.hostRestartListURL = listURL
        let exitHandler = center.onSessionExit
        center.onSessionExit = { [weak self] id, code, closedByApp in
            self?.exits.append((id, code, closedByApp))
            exitHandler?(id, code, closedByApp)
        }
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
        try? FileManager.default.removeItem(at: listDir)
        try await super.tearDown()
    }

    // MARK: Helpers

    /// The control connection the client holds now: the newest one still
    /// open that no session attached or launched on (the v2 hello the old
    /// host refused closed the first).
    private var control: FakeSessionHostTransport {
        transports.last { !$0.closed && $0.sent(.attach).isEmpty && $0.sent(.launch).isEmpty } ?? transports[0]
    }

    private func makeStep() -> HostRestartStep {
        let step = HostRestartStep(center: center, listURL: listURL) { [weak self] in self?.vm }
        step.workspaceNames = { [otherScope] in [otherScope: "acme-labs"] }
        step.signalHost = { [weak self] pid, sig in
            guard let self else { return }
            hostSignals.append((pid, sig))
            guard sig == SIGTERM, hostExitsOnTerm else { return }
            // The old host leaves: what answers next is a v2 host.
            hostV1 = false
        }
        step.hostIsAlive = { [weak self] _ in
            guard let self else { return false }
            return hostV1
        }
        step.sleep = { _ in }
        return step
    }

    private func sessionRow(kind: TerminalSession.Kind = .claude, folderPath: String? = nil) async throws -> TerminalSession {
        let path = folderPath ?? folder.path
        return try await pool.write { db in
            let projectID = try Int64.fetchOne(db, sql: "SELECT id FROM projects WHERE folder_path = ?", arguments: [path])
                ?? TestDatabase.insertWorkbench(db, name: "acme", folder: path)
            return try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: kind, title: "s", folderPath: path,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    private func run(_ row: Int64, pid: pid_t, scope: String? = nil, startedAtMs: Int64 = 1_760_000_000_000)
        -> SessionHostSessionInfo {
        alive.insert(pid)
        return SessionHostSessionInfo(row: row, run: "run-\(row)-\(pid)", pid: Int(pid), startedAtMs: startedAtMs,
                                      exited: false, code: nil, scope: scope ?? self.scope)
    }

    /// The launch: the host lists `runs`, the reattach adopts this
    /// workspace's ones.
    private func launch(listing runs: [SessionHostSessionInfo]) async {
        control.listed = runs
        await vm.reattachHostedSessions()
    }

    private func list() throws -> HostRestartList? {
        try HostRestartList.load(from: listURL)
    }

    // MARK: Step 0

    func testNothingHappensUntilContinue() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        XCTAssertEqual(center.states[row.id], .running)

        let step = makeStep()
        await step.runIfNeeded()

        XCTAssertEqual(step.phase, .waitingForContinue)
        XCTAssertEqual(step.notice?.text, HostRestartStep.noticeText)
        XCTAssertEqual(step.notice?.buttonTitle, HostRestartStep.continueTitle)
        XCTAssertTrue(signals.isEmpty, "no session is signalled before Continue")
        XCTAssertTrue(hostSignals.isEmpty, "the old host is left alone")
        XCTAssertNil(try list(), "no restart list before Continue")
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertEqual(factoryCalls, 0)

        // A quit without Continue, then the next launch: the notice comes back.
        let next = makeStep()
        await next.runIfNeeded()
        XCTAssertEqual(next.phase, .waitingForContinue)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(hostSignals.isEmpty)
        XCTAssertTrue(hostV1)
    }

    // MARK: Steps 1–2

    func testListIsWrittenBeforeAnyStop() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        var listedAtFirstStop: HostRestartList?
        onHangup = { [weak self] _ in
            guard let self, listedAtFirstStop == nil else { return }
            listedAtFirstStop = try? list()
        }
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        let atStop = try XCTUnwrap(listedAtFirstStop, "the list was on disk at the first signal")
        XCTAssertEqual(atStop.rows, [.init(scope: scope, rowID: row.id, agent: "claude",
                                           resumeID: row.claudeSessionID ?? "")])
        XCTAssertEqual(step.phase, .finished)
    }

    func testDropThenSignalSoNoCleanup() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let hosted = try XCTUnwrap(center.process(for: row.id) as? HostedTerminalSession)
        await hosted.connecting?.value
        let sessionTransport = try XCTUnwrap(transports.last)
        var heldAtHangup: [Bool] = []
        onHangup = { [weak self] pid in
            guard let self, pid == 5150 else { return }
            heldAtHangup.append(center.process(for: row.id) != nil)
            // The run exits on the hang-up, as Claude Code does.
            sessionTransport.push(.json(.exit, SessionHostExit(code: 129)))
        }
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(heldAtHangup, [false], "the run left the center's processes before its signal")
        XCTAssertEqual(signals.first.map { [$0.0, pid_t($0.1)] }, [5150, pid_t(SIGHUP)])
        let exit = try XCTUnwrap(exits.first { $0.0 == row.id })
        XCTAssertTrue(exit.2, "the exit is the app's: no PROJ-18 cleanup")
        XCTAssertTrue(vm.cleaningUpSessions.isEmpty)
        let forgot = try transports.flatMap { try $0.sent(.forget).map { try $0.decoded(SessionHostAttachRequest.self) } }
        XCTAssertTrue(forgot.contains(SessionHostAttachRequest(row: row.id, run: "run-\(row.id)-5150")),
                      "the run is forgotten in the old host")
        XCTAssertEqual(hostSignals.map { [$0.0, pid_t($0.1)] }, [[Self.oldHostPID, pid_t(SIGTERM)]],
                       "the idle old host gets SIGTERM, pid from its HelloOK")
    }

    // MARK: Step 3

    func testRelaunchWithResumeRemovesTheRow() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertNil(step.notice)
        XCTAssertTrue(client.speaksV2, "a v2 host serves the socket now")
        XCTAssertEqual(factoryCalls, 1, "one relaunch")
        XCTAssertEqual(center.states[row.id], .running)
        let uuid = try XCTUnwrap(row.claudeSessionID)
        let args = try XCTUnwrap(launched.first?.launches.first?.args.last)
        XCTAssertTrue(args.contains("claude --resume \(uuid)"), args)
        XCTAssertNotNil(vm.resumeStarts[row.id], "a resume: today's resume-failure check watches it")
        XCTAssertNil(try list(), "the launched row left the list")
    }

    func testOtherWorkspacesWaitAndShowTheLine() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150), run(7, pid: 6000, scope: otherScope)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertTrue(signals.contains { $0.0 == 6000 && $0.1 == SIGHUP }, "another workspace's run is stopped too")
        XCTAssertEqual(try list()?.rows, [.init(scope: otherScope, rowID: 7, agent: "", resumeID: "")],
                       "its row waits for that workspace's launch")
        XCTAssertEqual(step.waitingWorkspaces, [.init(name: "acme-labs", count: 1)])
        XCTAssertEqual(step.waitingWorkspaces.first?.line, "1 session waits to resume")
        XCTAssertEqual(factoryCalls, 1, "only this workspace's row relaunched")

        // That workspace's launch: a v2 host, its rows in the list — they relaunch with no notice.
        let other = try await sessionRow()
        try HostRestartList(rows: [.init(scope: scope, rowID: other.id, agent: "claude", resumeID: "")])
            .save(to: listURL)
        let launchStep = makeStep()
        await launchStep.runIfNeeded()
        XCTAssertEqual(launchStep.phase, .finished)
        XCTAssertEqual(center.states[other.id], .running)
        XCTAssertNil(try list())
        XCTAssertTrue(launchStep.waitingWorkspaces.isEmpty)
    }

    // MARK: Failures

    func testInterruptedRunResumesFromTheList() async throws {
        // Interrupted after step 1: the list holds A; the v1 host still runs A and B.
        let rowA = try await sessionRow()
        let rowB = try await sessionRow()
        try HostRestartList(rows: [.init(scope: scope, rowID: rowA.id, agent: "claude", resumeID: "")]).save(to: listURL)
        await launch(listing: [run(rowA.id, pid: 5150), run(rowB.id, pid: 5151)])

        let step = makeStep()
        await step.runIfNeeded()

        XCTAssertEqual(step.phase, .finished, "Continue was pressed before: no notice")
        XCTAssertEqual(center.states[rowA.id], .running)
        XCTAssertEqual(center.states[rowB.id], .running)
        XCTAssertEqual(factoryCalls, 2)
        XCTAssertNil(try list())

        // Interrupted in step 3: a row already relaunched is not relaunched again.
        try HostRestartList(rows: [.init(scope: scope, rowID: rowA.id, agent: "claude", resumeID: "")]).save(to: listURL)
        let again = makeStep()
        await again.runIfNeeded()
        XCTAssertEqual(again.phase, .finished)
        XCTAssertEqual(factoryCalls, 2, "the running row is skipped")
        XCTAssertNil(try list())
    }

    func testNoConversationEndsInResumeFailure() async throws {
        center.transcriptExists = { _ in false }
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(factoryCalls, 0, "never started anew on its own")
        XCTAssertTrue(vm.resumeFailed.contains(row.id), "the pane offers Start fresh")
        XCTAssertEqual(center.states[row.id], .exited(nil))
        XCTAssertNil(try list())
    }

    func testOtherLaunchFailureLeavesTheRowStoppedWithReason() async throws {
        let gone = listDir.appendingPathComponent("gone", isDirectory: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let row = try await sessionRow(folderPath: gone.path)
        await launch(listing: [run(row.id, pid: 5150)])
        try FileManager.default.removeItem(at: gone)
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(center.states[row.id], .unavailable("The folder \(gone.path) no longer exists."))
        XCTAssertFalse(exits.contains { $0.0 == row.id && !$0.2 }, "no natural exit, no cleanup")
        XCTAssertTrue(vm.cleaningUpSessions.isEmpty)
        XCTAssertNil(try list())
    }

    func testASaveFailureStopsNothing() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        // The list's folder is a file: the write fails.
        try FileManager.default.removeItem(at: listDir)
        try Data().write(to: listDir)
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .failed(HostRestartStep.saveFailed))
        XCTAssertEqual(step.notice?.buttonTitle, HostRestartStep.retryTitle)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(hostSignals.isEmpty)
        XCTAssertEqual(center.states[row.id], .running)
    }

    func testAHostThatDoesNotStartFailsAndRetryResumes() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        step.signalHost = { [weak self] pid, sig in
            self?.hostSignals.append((pid, sig))
            self?.hostV1 = false
            self?.hostUp = false // nothing serves the socket, and no CLI to start one
        }
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .failed(HostRestartStep.hostDidNotStart))
        XCTAssertEqual(step.notice?.buttonTitle, HostRestartStep.retryTitle)
        XCTAssertTrue(step.notice?.isError == true)
        XCTAssertEqual(try list()?.rows.map(\.rowID), [row.id], "the list keeps the row for Retry")
        XCTAssertEqual(factoryCalls, 0)

        hostUp = true
        await step.pressContinue()
        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(center.states[row.id], .running)
        XCTAssertNil(try list())
    }

    func testAnOldHostThatDoesNotExitFails() async throws {
        hostExitsOnTerm = false
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .failed(HostRestartStep.oldHostKept))
        XCTAssertEqual(try list()?.rows.map(\.rowID), [row.id])
        XCTAssertEqual(factoryCalls, 0, "nothing relaunches into the old host")
    }

    func testAV1HostWithNoLiveRunIsReplacedWithoutTheNotice() async throws {
        let step = makeStep()
        await step.runIfNeeded()
        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(hostSignals.map { $0.1 }, [SIGTERM])
        XCTAssertTrue(client.speaksV2)
    }

    func testAV2HostWithNoListNeedsNothing() async throws {
        hostV1 = false
        client.dropConnection()
        let step = makeStep()
        await step.runIfNeeded()
        XCTAssertEqual(step.phase, .notNeeded)
        XCTAssertNil(step.notice, "notNeeded renders nothing")
        XCTAssertTrue(hostSignals.isEmpty)
    }

    // MARK: Review round 1

    /// F1: a crash after step 2 killed a run and before its forget. The next
    /// launch's reattach must not adopt the exited run (its exit would read
    /// as natural, and PROJ-18 cleanup would run); the step resumes the row.
    func testACrashAfterAKillBeforeTheForgetNeverCleansUp() async throws {
        let row = try await sessionRow()
        try HostRestartList(rows: [.init(scope: scope, rowID: row.id, agent: "claude", resumeID: "")]).save(to: listURL)
        let killed = SessionHostSessionInfo(row: row.id, run: "run-killed", pid: 5150, startedAtMs: 1_760_000_000_000,
                                            exited: true, code: nil, scope: scope)
        await launch(listing: [killed])

        XCTAssertNil(center.process(for: row.id), "the killed run is not adopted")
        XCTAssertTrue(exits.isEmpty, "no exit is reported for it")
        let step = makeStep()
        await step.runIfNeeded()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertFalse(exits.contains { $0.0 == row.id && !$0.2 }, "never a natural exit: no cleanup")
        XCTAssertTrue(vm.cleaningUpSessions.isEmpty)
        XCTAssertEqual(center.states[row.id], .running, "the session resumes")
        let forgot = try transports.flatMap { try $0.sent(.forget).map { try $0.decoded(SessionHostAttachRequest.self) } }
        XCTAssertTrue(forgot.contains(SessionHostAttachRequest(row: row.id, run: "run-killed")))
        XCTAssertNil(try list())
    }

    /// F1: a refused forget (the child not reaped yet) is asked again.
    func testARefusedForgetIsRetried() async throws {
        let row = try await sessionRow()
        let oldControl = control // before the reattach opens a session connection
        await launch(listing: [run(row.id, pid: 5150)])
        oldControl.refusedForgets = 2
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(oldControl.refusedForgets, 0, "every refused forget was asked again")
        let forgot = try oldControl.sent(.forget).map { try $0.decoded(SessionHostAttachRequest.self) }
        XCTAssertGreaterThanOrEqual(forgot.filter { $0.row == row.id }.count, 3)
    }

    /// F2: a run started on the old host after step 1 is listed and stopped
    /// too, and a launch from the app while the runs stop is refused.
    func testARunStartedAfterStepOneIsListedAndStopped() async throws {
        let rowA = try await sessionRow()
        let rowB = try await sessionRow()
        let rowC = try await sessionRow()
        let oldControl = control
        await launch(listing: [run(rowA.id, pid: 5150)])
        let late = run(rowB.id, pid: 5152, startedAtMs: 1_760_000_100_000)
        var launchedDuringStop: [Bool] = []
        onHangup = { [weak self] pid in
            guard let self, pid == 5150 else { return }
            oldControl.listed.append(late) // the owner (or the phone) started B meanwhile
            launchedDuringStop.append(center.start(rowC, fresh: false) != nil)
        }
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(launchedDuringStop, [false], "no launch while the old host's runs stop")
        XCTAssertEqual(center.states[rowC.id], .unavailable(TerminalCenter.launchHeldReason))
        XCTAssertTrue(signals.contains { $0.0 == 5152 && $0.1 == SIGHUP }, "the late run is stopped")
        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(center.states[rowA.id], .running)
        XCTAssertEqual(center.states[rowB.id], .running, "the late run's row resumes too")
        XCTAssertFalse(center.launchesHeldForHostRestart)
    }

    /// A run that appears while the pid is confirmed is listed and stopped
    /// before the SIGTERM.
    func testARunStartedDuringThePidConfirmIsStoppedBeforeTheSignal() async throws {
        let rowA = try await sessionRow()
        let rowB = try await sessionRow()
        let oldControl = control
        await launch(listing: [run(rowA.id, pid: 5150)])
        let late = run(rowB.id, pid: 5153, startedAtMs: 1_760_000_200_000)
        var stoppedBeforeTerm: [Bool] = []
        onHangup = { [weak self] _ in
            // Armed once A is stopping: the next new connection is the pid confirm.
            self?.onNewTransport = { [weak self] in
                guard let self, oldControl.listed.count == 1 else { return }
                oldControl.listed.append(late)
            }
        }
        let step = makeStep()
        let term = step.signalHost
        step.signalHost = { [weak self] pid, sig in
            guard let self else { return }
            stoppedBeforeTerm.append(signals.contains { $0.0 == 5153 && $0.1 == SIGHUP })
            term(pid, sig)
        }
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(oldControl.listed.count, 2, "the late run appeared during the confirm")
        XCTAssertEqual(stoppedBeforeTerm, [true], "the late run was stopped before the SIGTERM")
        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(center.states[rowB.id], .running, "and resumes")
    }

    /// F3: the adoption's signal never fires while the notice waits.
    func testWaitUntilSettledWaitsForTheRestart() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        XCTAssertFalse(step.isSettled, "not settled before the launch's look")
        await step.runIfNeeded()
        XCTAssertEqual(step.phase, .waitingForContinue)
        XCTAssertFalse(step.isSettled)

        let waiter = Task { @MainActor [weak self] in
            await step.waitUntilSettled()
            self?.settledSeen = true
        }
        await Task.yield()
        XCTAssertFalse(settledSeen)
        await step.pressContinue()
        await waiter.value
        XCTAssertTrue(settledSeen)
        XCTAssertEqual(step.phase, .finished)
    }

    func testAFailureWithTheOldHostStillUpIsNotSettled() async throws {
        hostExitsOnTerm = false
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()
        XCTAssertEqual(step.phase, .failed(HostRestartStep.oldHostKept))
        XCTAssertFalse(step.isSettled, "the hub must not adopt beside a v1 host")
    }

    /// F4: an unreadable list is neither "no list" nor overwritten.
    func testAnUnreadableListIsKeptUntilSetAside() async throws {
        let row = try await sessionRow()
        try FileManager.default.createDirectory(at: listDir, withIntermediateDirectories: true)
        let garbage = Data("{not json".utf8)
        try garbage.write(to: listURL)
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        await step.runIfNeeded()

        XCTAssertEqual(step.phase, .listUnreadable)
        XCTAssertEqual(step.notice?.buttonTitle, HostRestartStep.retryTitle)
        XCTAssertEqual(step.notice?.secondaryTitle, HostRestartStep.setAsideTitle)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: listURL), garbage, "kept as it is")

        await step.pressContinue() // Retry reads it again: still unreadable, still kept
        XCTAssertEqual(step.phase, .listUnreadable)
        XCTAssertEqual(try Data(contentsOf: listURL), garbage)
        XCTAssertTrue(signals.isEmpty)

        await step.pressSetAside()
        XCTAssertEqual(try Data(contentsOf: HostRestartList.setAsideURL(for: listURL)), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: listURL.path))
        XCTAssertEqual(step.phase, .waitingForContinue, "without a list the owner is asked again")
        XCTAssertTrue(signals.isEmpty)
    }

    /// F5: a relaunch whose check fails says why in the pane and leaves the list.
    func testACodexRowWhoseCheckFailsShowsItsReason() async throws {
        center.codexRolloutExists = { _, _, _ in false }
        vm.resolveCodexHome = { nil }
        let row = try await sessionRow(kind: .codex)
        await launch(listing: [run(row.id, pid: 5150)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .finished)
        XCTAssertEqual(center.states[row.id], .unavailable(WorkbenchesViewModel.hostRestartCodexUnchecked))
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertNil(try list())
    }

    /// F5: a row that could not even be read stays in the list for Retry.
    func testARowThatCannotBeReadStaysInTheList() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        onHangup = { [weak self] _ in try? self?.pool.close() } // the database goes away mid-step
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .failed(HostRestartStep.relaunchIncomplete))
        XCTAssertTrue(step.isSettled, "a v2 host answers: the hub need not wait for a Retry")
        XCTAssertEqual(try list()?.rows.map(\.rowID), [row.id])
    }

    /// F6: the launch's sweep keeps the pasted files of a row still listed.
    func testTheAttachmentSweepKeepsListedRows() async throws {
        let store = WorkchatAttachmentStore(root: listDir.appendingPathComponent("attachments", isDirectory: true))
        vm.attachmentStore = store
        let pasted = try store.save(Data("x".utf8), name: "a.png", sessionID: 41)
        try HostRestartList(rows: [.init(scope: scope, rowID: 41, agent: "claude", resumeID: "")]).save(to: listURL)

        await vm.sweepAttachmentsAfterReattach()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pasted.path))

        try HostRestartList().save(to: listURL)
        await vm.sweepAttachmentsAfterReattach()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pasted.path), "once out of the list, swept as before")
    }

    /// F8: rows of a workspace that is no longer here keep a line, and Clear drops them.
    func testRowsOfAMissingWorkspaceShowALineAndClear() throws {
        try HostRestartList(rows: [
            .init(scope: otherScope, rowID: 1, agent: "", resumeID: ""),
            .init(scope: "cccc3333cccc3333", rowID: 2, agent: "", resumeID: ""),
            .init(scope: "cccc3333cccc3333", rowID: 3, agent: "", resumeID: "")
        ]).save(to: listURL)
        let step = makeStep()
        step.refreshWaiting()
        XCTAssertEqual(step.waitingWorkspaces, [.init(name: "acme-labs", count: 1)])
        XCTAssertEqual(step.orphanedCount, 2)

        step.clearOrphans()
        XCTAssertEqual(step.orphanedCount, 0)
        XCTAssertEqual(try list()?.rows.map(\.scope), [otherScope], "only the missing workspace's rows go")
    }

    /// F9: a second workspace (its own scope and database) resumes its rows
    /// at its launch, from a list row with no agent or resume id.
    func testAnotherWorkspaceResumesItsRowsAtItsLaunch() async throws {
        let row = try await sessionRow()
        let (otherPool, otherPath) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: otherPath) }
        let path = folder.path
        let otherRow = try await otherPool.write { db in
            let projectID = try TestDatabase.insertWorkbench(db, name: "acme-labs", folder: path)
            return try TerminalSessionQueries.create(db, .init(
                projectID: projectID, kind: .claude, title: "o", folderPath: path,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        await launch(listing: [run(row.id, pid: 5150), run(otherRow.id, pid: 6000, scope: otherScope)])
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()
        XCTAssertEqual(try list()?.rows, [.init(scope: otherScope, rowID: otherRow.id, agent: "", resumeID: "")])

        // The other workspace opens: its own center, database and scope, the v2 host.
        var otherLaunched: [FakeTerminalSession] = []
        let otherCenter = TerminalCenter {
            let process = FakeTerminalSession()
            otherLaunched.append(process)
            return process
        }
        otherCenter.shell = { "/bin/zsh" }
        otherCenter.transcriptExists = { _ in true }
        otherCenter.sessionHostScope = otherScope
        otherCenter.sessionHost = client
        let otherVM = WorkbenchesViewModel(dbPool: otherPool, cli: WorkbenchCLI(runner: FakeCLIRunner()),
                                           defaults: defaults, terminalCenter: otherCenter)
        otherVM.hostRestartListURL = listURL
        await otherVM.reattachHostedSessions()
        let otherStep = HostRestartStep(center: otherCenter, listURL: listURL) { otherVM }
        otherStep.workspaceNames = { [scope] in [scope: "acme"] }
        await otherStep.runIfNeeded()

        XCTAssertEqual(otherStep.phase, .finished)
        XCTAssertEqual(otherCenter.states[otherRow.id], .running)
        let uuid = try XCTUnwrap(otherRow.claudeSessionID)
        let args = try XCTUnwrap(otherLaunched.first?.launches.first?.args.last)
        XCTAssertTrue(args.contains("claude --resume \(uuid)"), "the id comes from that workspace's row: \(args)")
        XCTAssertNil(try list())
    }

    /// F11: SIGTERM goes only to the pid a fresh Hello confirms.
    func testAnUnconfirmedOldHostPidIsNotSignalled() async throws {
        let row = try await sessionRow()
        await launch(listing: [run(row.id, pid: 5150)])
        onHangup = { [weak self] _ in self?.hostUp = false } // the fresh Hello reaches nothing
        let step = makeStep()
        await step.runIfNeeded()
        await step.pressContinue()

        XCTAssertEqual(step.phase, .failed(HostRestartStep.oldHostUnconfirmed))
        XCTAssertTrue(hostSignals.isEmpty, "no SIGTERM to an unconfirmed pid")
        XCTAssertEqual(try list()?.rows.map(\.rowID), [row.id])
    }

    func testBusyStatesKeepContinueOff() {
        let stopping = HostRestartStep.notice(for: .stopping(done: 2, total: 5))
        XCTAssertEqual(stopping?.text, "Stopping sessions… 2 of 5")
        XCTAssertEqual(stopping?.progress, 0.4)
        XCTAssertEqual(stopping?.buttonEnabled, false)
        let relaunching = HostRestartStep.notice(for: .relaunching(done: 1, total: 4))
        XCTAssertEqual(relaunching?.text, "Resuming sessions… 1 of 4")
        XCTAssertEqual(relaunching?.buttonEnabled, false)
        XCTAssertNil(HostRestartStep.notice(for: .notNeeded))
        XCTAssertNil(HostRestartStep.notice(for: .finished))
    }

    func testCopyIsInTheModel() {
        XCTAssertEqual(HostRestartStep.noticeText,
                       "Running sessions restart once with this update; their conversations continue")
        XCTAssertEqual(HostRestartStep.continueTitle, "Continue")
        XCTAssertEqual(HostRestartStep.retryTitle, "Retry")
        XCTAssertEqual(HostRestartStep.waitLine(1), "1 session waits to resume")
        XCTAssertEqual(HostRestartStep.waitLine(3), "3 sessions wait to resume")
        XCTAssertEqual(HostRestartStep.failedTitle, "Sessions could not be restarted")
        XCTAssertEqual(HostRestartStep.hostDidNotStart, "The session host did not start. Your sessions resume on Retry.")
        XCTAssertEqual(TerminalCenter.noSessionHostReason, "[Watchtower] the session host is not running")
        XCTAssertEqual(HostRestartStep.orphanLine(1), "1 session waits to resume in a workspace that is no longer here")
        XCTAssertEqual(HostRestartStep.orphanLine(2), "2 sessions wait to resume in a workspace that is no longer here")
        XCTAssertEqual(HostRestartStep.setAsideTitle, "Set Aside")
        XCTAssertEqual(HostRestartStep.clearTitle, "Clear")
        XCTAssertEqual(HostRestartStep.listUnreadableTitle, "The list of sessions to resume could not be read")
        XCTAssertEqual(TerminalCenter.launchHeldReason,
                       "[Watchtower] Sessions are restarting after the update. Try again in a moment.")
    }
}
