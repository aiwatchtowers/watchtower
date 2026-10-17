import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// `session_start` and `session_stop` from the phone on the hub (mobile POC
/// spec §5.2, §6.5): the device grants, the brief, the board scope, the
/// placement, claude-not-found, and the relay's age, echoes and ledger
/// around a real start.
@MainActor
final class SessionStartHandlerTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var signals: [(pid_t, Int32)] = []
    /// A phone allowed to start but not to type (the handler reads only
    /// the start flag; `MobileLinkCenter.sessionGrant` ties it to typing).
    private static let mayStart = SessionStartStopHandlers.DeviceGrant(typingAllowed: false, startSessionsAllowed: true)
    private var grant = mayStart
    private var grantedDevices: [String?] = []
    private var broughtForward: [Int64] = []
    /// Runs inside each launch-watch pause (the process exiting meanwhile).
    private var onPause: (() throws -> Void)?
    private var pauses = 0
    private var heldVM: WorkbenchesViewModel?

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionStartHandlerTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt start \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("acme"), withIntermediateDirectories: true)
        processes = []
        signals = []
        grant = Self.mayStart
        grantedDevices = []
        broughtForward = []
        onPause = nil
        pauses = 0
        heldVM = nil
        // Fake processes: a SIGHUP ends one at once; nothing real is signalled.
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession(pid: 4242 + pid_t(self?.processes.count ?? 0))
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(
                signal: { [weak self] pid, sig in
                    self?.signals.append((pid, sig))
                    if sig == SIGHUP { self?.processes.first { $0.pid == pid }?.exit(nil) }
                },
                isAlive: { _ in false },
                sleep: { _ in }
            )
        )
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
    }

    override func tearDown() {
        heldVM = nil
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var acme: String { folder.appendingPathComponent("acme").path }
    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        return vm
    }

    /// The handlers hold the view model weakly, as AppState owns it.
    private func makeHandlers(_ vm: WorkbenchesViewModel?) -> SessionStartStopHandlers {
        heldVM = vm
        return SessionStartStopHandlers(
            dbPool: pool, workbenches: vm, terminalCenter: center,
            deviceGrant: { [weak self] device in
                self?.grantedDevices.append(device)
                return self?.grant ?? .denied
            },
            bringForward: { [weak self] in self?.broughtForward.append($0) },
            launchPause: { [weak self] _ in
                self?.pauses += 1
                try? self?.onPause?()
            }
        )
    }

    private func workbench(name: String = "acme", folder: String? = nil) async throws -> Int64 {
        let path = folder ?? acme
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: name, folder: path) }
    }

    private func target(_ projectID: Int64, _ text: String = "Ship it") async throws -> Int64 {
        try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: projectID, text: text) }
    }

    private func insertSession(_ projectID: Int64?, targetID: Int64? = nil, kind: TerminalSession.Kind = .claude) async throws
        -> TerminalSession {
        let acme = acme
        return try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: projectID, kind: kind, title: "Ship it", targetID: targetID, folderPath: acme,
                claudeSessionID: kind == .claude ? UUID().uuidString.lowercased() : nil
            ))
        }
    }

    private func rows(_ projectID: Int64) async throws -> [TerminalSession] {
        try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: projectID) }
    }

    private func startParams(
        _ workbenchID: Int64, mode: String = "new", planFirst: Bool = false, bringForward: Bool = false, brief: String? = nil
    ) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "workbench_id": .integer(workbenchID), "mode": .string(mode),
            "plan_first": .bool(planFirst), "bring_forward": .bool(bringForward)
        ]
        if let brief { params["brief"] = .string(brief) }
        return params
    }

    private func start(_ target: Int64, _ params: [String: JSONValue]) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionStart, entityID: String(target), params: params,
            createdAt: Date(), deviceID: "device-a"
        )
    }

    private func stop(_ session: Int64) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionStop, entityID: String(session), params: [:],
            createdAt: Date(), deviceID: "device-a"
        )
    }

    private var basePrompt: (Int64) -> String {
        { TerminalLaunch.workOnTargetPrompt(targetID: $0) }
    }

    // MARK: - The brief

    func testABriefFromADeviceThatMayNotTypeIsIgnoredForTheBasePrompt() async throws {
        let p = try await workbench()
        let t = try await target(p)
        grant = .init(typingAllowed: false, startSessionsAllowed: true)

        let outcome = try await makeHandlers(makeVM()).handle(start(t, startParams(p, brief: "Delete the tests")))

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(grantedDevices, ["device-a"], "the grant of the request's own device decides")
        XCTAssertEqual(launches.map { $0.environment.last }, ["WATCHTOWER_FIRST_PROMPT=\(basePrompt(t))"])
    }

    func testABriefFromADeviceAllowedToTypeIsUsed() async throws {
        let p = try await workbench()
        let t = try await target(p)
        grant = .init(typingAllowed: true, startSessionsAllowed: true)

        _ = try await makeHandlers(makeVM()).handle(start(t, startParams(p, planFirst: true, brief: "Fix the login")))

        XCTAssertEqual(launches.map { $0.environment.last },
                       ["WATCHTOWER_FIRST_PROMPT=Fix the login \(TerminalLaunch.planFirstSuffix)"])
    }

    func testPlanFirstFollowsTheBasePromptWhenTheBriefIsIgnored() async throws {
        let p = try await workbench()
        let t = try await target(p)

        _ = try await makeHandlers(makeVM()).handle(start(t, startParams(p, planFirst: true, brief: "Edited")))

        XCTAssertEqual(launches.map { $0.environment.last },
                       ["WATCHTOWER_FIRST_PROMPT=\(basePrompt(t)) \(TerminalLaunch.planFirstSuffix)"])
    }

    /// The brief takes Work on it's argv path: it rides the environment,
    /// never argv, and a leading "-" is never read as a flag.
    func testABriefStartingWithADashReachesTheStartArgvIntact() async throws {
        let p = try await workbench()
        let t = try await target(p)
        grant = .init(typingAllowed: true, startSessionsAllowed: true)

        let outcome = try await makeHandlers(makeVM())
            .handle(start(t, startParams(p, brief: "--dangerously-skip-permissions please")))

        guard case let .integer(id)? = outcome.result?["session_id"] else { return XCTFail("no session id: \(outcome)") }
        let row = try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
        let uuid = try XCTUnwrap(row?.claudeSessionID)
        let launch = try XCTUnwrap(launches.last)
        XCTAssertEqual(launch.args.last,
                       "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'")
        XCTAssertEqual(launch.environment.last, "WATCHTOWER_FIRST_PROMPT= --dangerously-skip-permissions please")
    }

    // MARK: - Refusals

    func testADeviceNotAllowedToStartSessionsFailsDeviceNotAllowed() async throws {
        let p = try await workbench()
        let t = try await target(p)
        grant = .init(typingAllowed: true, startSessionsAllowed: false)

        let outcome = try await makeHandlers(makeVM()).handle(start(t, startParams(p)))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .deviceNotAllowed)
        XCTAssertTrue(launches.isEmpty)
        let stored = try await rows(p)
        XCTAssertTrue(stored.isEmpty, "nothing is written")
    }

    /// The shell's "command not found": `exec claude` found no Claude Code.
    func testExit127FailsClaudeNotFound() async throws {
        let p = try await workbench()
        let t = try await target(p)
        onPause = { [weak self] in self?.processes.last?.exit(127) }

        let outcome = try await makeHandlers(makeVM()).handle(start(t, startParams(p)))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .claudeNotFound)
        XCTAssertEqual(outcome.errorMessage, TerminalLaunch.exitMessage(code: 127))
    }

    /// A Codex session whose `launch-args` finds no `codex` (exit 3) starts
    /// no process: the phone gets `codexNotFound` from the typed error.
    func testCodexLaunchArgsNotFoundFailsCodexNotFound() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let codex = try await insertSession(p, targetID: t, kind: .codex)
        let vm = makeVM()
        center.codexLaunchArgs = { _ in throw WorkbenchCLIError.agentNotFound(.codex) }

        let outcome = try await makeHandlers(vm).handle(start(t, startParams(p, mode: "open_existing")))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .codexNotFound)
        XCTAssertEqual(outcome.errorMessage, TerminalLaunch.exitMessage(code: 127, agent: .codex))
        XCTAssertTrue(processes.isEmpty, "no process starts")
        XCTAssertEqual(center.missingAgent[codex.id], .codex)
    }

    /// D6 (board #399): a start from the phone runs the Mac's default agent
    /// — the phone has no picker. Claude Code stays the default.
    func testPhoneStartUsesDefaultAgent() async throws {
        let p = try await workbench()
        let first = try await target(p)
        let vm = makeVM()
        let claudeOutcome = try await makeHandlers(vm).handle(start(first, startParams(p)))
        XCTAssertEqual(claudeOutcome.status, .applied)
        let claudeRows = try await rows(p)
        XCTAssertEqual(claudeRows.map(\.kind), [.claude])

        let second = try await target(p, "Ship that")
        vm.readDefaultAgent = { .codex }
        center.codexLaunchArgs = { _ in CodexLaunchArgs(binary: "/Users/example/bin/codex", pathPrepend: "", args: []) }
        let codexOutcome = try await makeHandlers(vm).handle(start(second, startParams(p)))
        XCTAssertEqual(codexOutcome.status, .applied)
        let all = try await rows(p)
        let codex = try XCTUnwrap(all.first { $0.targetID == second })
        XCTAssertEqual(codex.kind, .codex)
        XCTAssertNil(codex.claudeSessionID, "Codex mints its own id")
        XCTAssertTrue(launches.last?.environment.contains { $0.hasPrefix("WATCHTOWER_CODEX_COMMAND=") } == true,
                      "the Codex launch ran")
    }

    /// End to end: the default agent is Codex and `launch-args` finds no
    /// `codex` — a new session from the phone fails `codexNotFound`, with
    /// Codex's message and no process.
    func testPhoneStartCodexMissingReturnsCodexNotFound() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let vm = makeVM()
        vm.readDefaultAgent = { .codex }
        center.codexLaunchArgs = { _ in throw WorkbenchCLIError.agentNotFound(.codex) }

        let outcome = try await makeHandlers(vm).handle(start(t, startParams(p)))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .codexNotFound)
        XCTAssertEqual(outcome.errorMessage, TerminalLaunch.exitMessage(code: 127, agent: .codex))
        XCTAssertTrue(processes.isEmpty, "no process starts")
        let created = try await rows(p)
        XCTAssertEqual(created.map(\.kind), [.codex])
    }

    /// Any other launch-args failure is no not-found: a plain write failure.
    func testCodexLaunchArgsOtherFailureIsNoNotFound() async throws {
        let p = try await workbench()
        let t = try await target(p)
        _ = try await insertSession(p, targetID: t, kind: .codex)
        let vm = makeVM()
        center.codexLaunchArgs = { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "broken config") }

        let outcome = try await makeHandlers(vm).handle(start(t, startParams(p, mode: "open_existing")))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .writeFailed)
        XCTAssertTrue(processes.isEmpty)
    }

    /// Any other early exit is the session's own end: the start itself ran.
    func testAnotherEarlyExitIsStillAStart() async throws {
        let p = try await workbench()
        let t = try await target(p)
        onPause = { [weak self] in self?.processes.last?.exit(1) }

        let outcome = try await makeHandlers(makeVM()).handle(start(t, startParams(p)))

        XCTAssertEqual(outcome.status, .applied)
    }

    func testATargetNotOnABoardFailsNotOnBoard() async throws {
        let p = try await workbench()
        let loose = try await pool.write { try TestDatabase.insertTarget($0, text: "Loose") }

        let outcome = try await makeHandlers(makeVM()).handle(start(loose, startParams(p)))

        XCTAssertEqual(outcome.reason, .notOnBoard)
        XCTAssertTrue(launches.isEmpty)
    }

    func testATargetOfAnotherWorkbenchFailsNotOnBoard() async throws {
        let p = try await workbench()
        let other = try await workbench(name: "acme-other", folder: folder.appendingPathComponent("other").path)
        let t = try await target(other)

        let outcome = try await makeHandlers(makeVM()).handle(start(t, startParams(p)))

        XCTAssertEqual(outcome.reason, .notOnBoard)
        XCTAssertTrue(launches.isEmpty)
    }

    func testAMissingTargetOrWorkbenchFailsNotFound() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let handlers = makeHandlers(makeVM())

        let gone = try await handlers.handle(start(t + 100, startParams(p)))
        let noWorkbench = try await handlers.handle(start(t, startParams(p + 100)))

        XCTAssertEqual(gone.reason, .notFound)
        XCTAssertEqual(noWorkbench.reason, .notFound)
        XCTAssertTrue(launches.isEmpty)
    }

    func testBadParamsFailInvalidParams() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let handlers = makeHandlers(makeVM())
        var noFlags = startParams(p)
        noFlags["plan_first"] = nil

        let badMode = try await handlers.handle(start(t, startParams(p, mode: "resume")))
        let missing = try await handlers.handle(start(t, noFlags))

        XCTAssertEqual(badMode.reason, .invalidParams)
        XCTAssertEqual(missing.reason, .invalidParams)
        XCTAssertTrue(launches.isEmpty)
    }

    /// A rebuilt workbench state (no view model yet) starts nothing and
    /// never reports a start.
    func testNoWorkbenchStateFailsWriteFailed() async throws {
        let p = try await workbench()
        let t = try await target(p)

        let outcome = try await makeHandlers(nil).handle(start(t, startParams(p)))

        XCTAssertEqual(outcome.reason, .writeFailed)
        XCTAssertTrue(launches.isEmpty)
    }

    // MARK: - Placement and modes

    func testBringForwardOffStartsInTheBackground() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let vm = makeVM()

        let outcome = try await makeHandlers(vm).handle(start(t, startParams(p, bringForward: false)))

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertTrue(broughtForward.isEmpty)
        XCTAssertTrue(center.focusOrder.isEmpty, "nothing on the owner's screen moves")
    }

    func testBringForwardOnBringsTheWorkbenchForwardAndKeepsTheBoard() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p // what AppState's bring-forward does first

        let outcome = try await makeHandlers(vm).handle(start(t, startParams(p, bringForward: true)))

        guard case let .integer(id)? = outcome.result?["session_id"] else { return XCTFail("no session id: \(outcome)") }
        XCTAssertEqual(broughtForward, [p])
        XCTAssertEqual(center.focusOrder.last, id, "Work on it: the session is focused")
        XCTAssertEqual(vm.layout(projectID: p).primary, .session(id))
    }

    /// `open_existing` reuses the target's session (its conversation
    /// resumes: neither the brief nor plan first is sent).
    func testOpenExistingAnswersTheTargetsSession() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let existing = try await insertSession(p, targetID: t)
        grant = .init(typingAllowed: true, startSessionsAllowed: true)

        let outcome = try await makeHandlers(makeVM())
            .handle(start(t, startParams(p, mode: "open_existing", planFirst: true, brief: "Edited")))

        XCTAssertEqual(outcome, .applied(["session_id": .integer(existing.id), "stage": .string("starting")]))
        let stored = try await rows(p)
        XCTAssertEqual(stored.count, 1, "no new row")
        XCTAssertEqual(launches.count, 1)
        let launch = try XCTUnwrap(launches.first)
        XCTAssertTrue(launch.environment.allSatisfy { !$0.hasPrefix("WATCHTOWER_FIRST_PROMPT=") }, "it resumes")
    }

    /// A session the owner just deleted waits hidden in the Undo batch
    /// (PROJ-17): the phone's "open existing" never resumes it — a new
    /// session starts instead.
    func testOpenExistingNeverPicksAPendingDelete() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let deleted = try await insertSession(p, targetID: t)
        let vm = makeVM()
        vm.deleteSleep = { _ in try? await Task.sleep(for: .seconds(60)) } // cancelled below, never waited out
        defer { vm.deleteCommitTask?.cancel() }
        await vm.reload()
        await vm.delete(deleted)

        let outcome = try await makeHandlers(vm).handle(start(t, startParams(p, mode: "open_existing")))

        let started = try XCTUnwrap(outcome.result?["session_id"])
        XCTAssertNotEqual(started, .integer(deleted.id))
        let stored = try await rows(p)
        XCTAssertEqual(stored.count, 2, "a new row; the hidden one waits for its window")
        XCTAssertFalse(center.liveIDs.contains(deleted.id))
    }

    /// An already running session needs no launch watch.
    func testOpenExistingOnALiveSessionDoesNotWatchTheLaunch() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let existing = try await insertSession(p, targetID: t)
        center.start(existing, fresh: false)

        let outcome = try await makeHandlers(makeVM()).handle(start(t, startParams(p, mode: "open_existing")))

        XCTAssertEqual(outcome.result?["session_id"], .integer(existing.id))
        XCTAssertEqual(pauses, 0)
    }

    // MARK: - The relay around a start (§5.2 rules 1, 5, 6)

    private func relay(now: Date = Date()) throws -> (StubHubTransport, HubSyncState, RelayProcessor, SessionStartStopHandlers) {
        let transport = StubHubTransport()
        let sidecar = try HubSyncState.inMemory()
        try sidecar.linkTestDevice()
        let dispatcher = MobileHubCommandDispatcher()
        let handlers = makeHandlers(makeVM())
        handlers.register(on: dispatcher)
        let processor = RelayProcessor(transport: transport.sealing(), sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme") { now }
        return (transport, sidecar, processor, handlers)
    }

    private func echoes(_ transport: StubHubTransport, of recordName: String) throws -> [ActionRequestPayload] {
        try transport.saved
            .filter { $0.record.recordName == recordName }
            .map { try decodeAction($0.record) }
            .filter { $0.status != .pending }
    }

    func testTheEchoesAreReceivedThenAppliedWithTheSessionAndBegunPrecedesTheStart() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let (transport, sidecar, processor, _) = try relay()
        let record = try pendingActionRecord(kind: .sessionStart, entityID: String(t), params: startParams(p))
        var phaseAtStart: HubSyncState.RelayPhase?
        var echoesAtStart: [ActionStatus] = []
        onPause = { [weak self] in
            guard self?.pauses == 1 else { return }
            phaseAtStart = try sidecar.relayPhase(record.plainName)
            echoesAtStart = try self?.echoes(transport, of: record.recordName).map(\.status) ?? []
        }
        try await transport.save([record])

        _ = try await processor.processOnce()

        let echoes = try echoes(transport, of: record.recordName)
        XCTAssertEqual(echoes.map(\.status), [.received, .applied])
        let stored = try await rows(p)
        let row = try XCTUnwrap(stored.first)
        XCTAssertEqual(echoes.last?.result, ["session_id": .integer(row.id), "stage": .string("starting")])
        XCTAssertEqual(phaseAtStart, .begun, "`begun` is committed before the start")
        XCTAssertEqual(echoesAtStart, [.received], "`received` is written before any work")
        XCTAssertEqual(try sidecar.relayPhase(record.plainName), .done)
    }

    /// The hub stopped between `begun` and `done`: never a second session.
    func testACrashBetweenBegunAndDoneIsOutcomeUnknownAndNeverASecondSession() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let (transport, sidecar, processor, _) = try relay()
        let record = try pendingActionRecord(kind: .sessionStart, entityID: String(t), params: startParams(p))
        try await transport.save([record])
        try sidecar.markRelayBegun(record.plainName, at: Date())

        _ = try await processor.processOnce()
        try await transport.save([record])
        _ = try await processor.processOnce()

        let echoes = try echoes(transport, of: record.recordName)
        XCTAssertEqual(echoes.map(\.status), [.failed, .failed], "the second read re-echoes the stored outcome")
        XCTAssertEqual(echoes.map(\.reason), [.outcomeUnknown, .outcomeUnknown])
        XCTAssertTrue(launches.isEmpty)
        let stored = try await rows(p)
        XCTAssertTrue(stored.isEmpty)
    }

    func testAStartOlderThanADayExpiresAndOneOf23HoursIsApplied() async throws {
        let p = try await workbench()
        let t = try await target(p)
        let now = Date()
        let (transport, _, processor, _) = try relay(now: now)
        let stale = try pendingActionRecord(kind: .sessionStart, entityID: String(t), params: startParams(p),
                                            age: 86_400 + 1, now: now)
        let fresh = try pendingActionRecord(kind: .sessionStart, entityID: String(t), params: startParams(p),
                                            age: 23 * 3600, now: now)
        try await transport.save([stale, fresh])

        _ = try await processor.processOnce()

        XCTAssertEqual(try echoes(transport, of: stale.recordName).map(\.status), [.expired])
        XCTAssertEqual(try echoes(transport, of: stale.recordName).first?.reason, .expired)
        XCTAssertEqual(try echoes(transport, of: fresh.recordName).map(\.status), [.received, .applied])
        XCTAssertEqual(launches.count, 1, "only the fresh request starts a session")
    }

    // MARK: - Stop

    func testStopOnAStoppedSessionIsAppliedWithNoSignal() async throws {
        let p = try await workbench()
        let session = try await insertSession(p)

        let outcome = try await makeHandlers(makeVM()).handle(stop(session.id))

        XCTAssertEqual(outcome, .applied())
        XCTAssertTrue(signals.isEmpty)
    }

    func testStopOnALiveSessionClosesItOnce() async throws {
        let p = try await workbench()
        let session = try await insertSession(p)
        center.start(session, fresh: false)
        let pid = try XCTUnwrap(processes.last?.pid)
        let handlers = makeHandlers(makeVM())

        let first = try await handlers.handle(stop(session.id))
        let again = try await handlers.handle(stop(session.id))

        XCTAssertEqual(first, .applied())
        XCTAssertEqual(again, .applied(), "idempotent: a stopped session is applied again")
        XCTAssertEqual(signals.map(\.0), [pid])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
        XCTAssertFalse(center.liveIDs.contains(session.id))
    }

    /// The phone sees codex board sessions, so it may stop one (board #399);
    /// a shell on the board stays out of reach.
    func testStopOnACodexBoardSessionIsAppliedAndOnAShellFailsNotFound() async throws {
        let p = try await workbench()
        let codex = try await insertSession(p, kind: .codex)
        let shell = try await insertSession(p, kind: .shell)
        let handlers = makeHandlers(makeVM())

        let codexOutcome = try await handlers.handle(stop(codex.id))
        let shellOutcome = try await handlers.handle(stop(shell.id))

        XCTAssertEqual(codexOutcome, .applied())
        XCTAssertEqual(shellOutcome.reason, .notFound)
    }

    /// Exit 127 names the agent that was not found.
    func testExit127ReasonFollowsTheSessionsAgent() {
        XCTAssertEqual(SessionStartStopHandlers.notFoundReason(.claude), .claudeNotFound)
        XCTAssertEqual(SessionStartStopHandlers.notFoundReason(.codex), .codexNotFound)
    }

    func testStopOnAnUnknownOrNonBoardSessionFailsNotFound() async throws {
        let standalone = try await insertSession(nil)
        center.start(standalone, fresh: false)
        let handlers = makeHandlers(makeVM())

        let unknown = try await handlers.handle(stop(standalone.id + 100))
        let loose = try await handlers.handle(stop(standalone.id))

        XCTAssertEqual(unknown.reason, .notFound)
        XCTAssertEqual(loose.reason, .notFound)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(center.liveIDs.contains(standalone.id))
    }
}
