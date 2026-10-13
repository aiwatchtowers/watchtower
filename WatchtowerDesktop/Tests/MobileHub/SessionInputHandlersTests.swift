import AppKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// A process that records what was typed into it and its launches.
@MainActor
private final class InputProbeSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)?
    var bracketedPasteMode = true
    private(set) var inputs: [[UInt8]] = []
    private(set) var launches: [TerminalLaunch] = []

    func start(_ launch: TerminalLaunch) { launches.append(launch) }
    func detach() {}
    func sendInput(_ bytes: [UInt8]) { inputs.append(bytes) }
}

/// Counts the state reads.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int { lock.withLock { reads } }

    func add() { lock.withLock { reads += 1 } }
}

/// The later echoes the handlers wrote.
@MainActor
private final class EchoLog {
    private(set) var items: [(action: ActionRequestPayload, outcome: ActionOutcome)] = []

    func append(_ action: ActionRequestPayload, _ outcome: ActionOutcome) { items.append((action, outcome)) }

    func outcomes(of action: ActionRequestPayload) -> [ActionOutcome] {
        items.filter { $0.action.id == action.id }.map(\.outcome)
    }
}

/// Session input from the phone (mobile POC spec §5.2, §6.6, PROJ-16): a
/// line goes only from an allowed device, only while the agent is idle and
/// the prompt holds no text, only through `SessionLineDelivery` (PROJ-12),
/// never into a permission prompt; held lines are echoed with their reason,
/// expire after 24 h, survive a hub restart, fail on a revoke and can be
/// cancelled.
@MainActor
final class SessionInputHandlersTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [InputProbeSession] = []
    private var center: TerminalCenter!
    private var delivery: SessionLineDelivery!
    private var sidecar: HubSyncState!
    private var statuses: [Int64: SessionAgentStatus] = [:]
    private var readsSucceed = true
    /// Runs inside the next state read a delivery makes (once).
    private var duringRead: (() async -> Void)?
    private var clock: LinkTestClock!
    private var echoes: EchoLog!
    private var workbenchID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionInputHandlersTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt input \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        statuses = [:]
        readsSucceed = true
        clock = LinkTestClock(Date())
        echoes = EchoLog()
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = InputProbeSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
        center.transcriptExists = { _ in true }
        delivery = SessionLineDelivery(terminalCenter: center)
        delivery.refreshStates = { [weak self] in
            if let during = self?.duringRead {
                self?.duringRead = nil
                await during()
            }
            return self?.readsSucceed ?? false
        }
        let deliveryClock = try XCTUnwrap(clock)
        delivery.now = { deliveryClock.now }
        delivery.needsApproval = { [weak self] in self?.statuses[$0]?.state.kind == .needsApproval }
        delivery.hasHookState = { [weak self] in self?.statuses[$0]?.hooksReported == true }
        sidecar = try HubSyncState.inMemory()
        try sidecar.linkTestDevice("device-a")
        _ = try sidecar.setDeviceGrant(.typing, true, deviceID: "device-a", at: Date())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    private func makeHandlers(
        lateEcho: RelayProcessor.LateEcho? = nil
    ) throws -> SessionInputHandlers {
        let log = try XCTUnwrap(echoes)
        let clock = try XCTUnwrap(clock)
        let sidecar = try XCTUnwrap(sidecar)
        return SessionInputHandlers(
            dbPool: pool, sidecar: sidecar, lineDelivery: delivery, terminalCenter: center,
            status: { [weak self] in self?.statuses[$0] },
            deviceGrant: { MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
            lateEcho: lateEcho ?? { action, outcome in await log.append(action, outcome) },
            now: { clock.now } // swiftlint:disable:this trailing_closure
        )
    }

    /// A workbench with one running `claude` session.
    private func liveSession() async throws -> Int64 {
        let acme = folder.path
        let session = try await pool.write { db -> TerminalSession in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .claude, title: "Ship it", folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        workbenchID = try XCTUnwrap(session.projectID)
        center.start(session, fresh: true)
        XCTAssertTrue(center.liveIDs.contains(session.id))
        return session.id
    }

    /// The session's resolved state, as the state center would publish it:
    /// a hook state of this run.
    private func setState(
        _ sessionID: Int64, _ kind: SessionSwitcherPresentation.State.Kind, at: String = "2026-10-12T10:00:00.000Z"
    ) {
        statuses[sessionID] = SessionAgentStatus(
            sessionID: sessionID, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: kind, live: true), at: at
        )
    }

    private func input(_ sessionID: Int64, _ text: String, device: String = "device-a") -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionInput, entityID: String(sessionID), params: ["text": .string(text)],
            createdAt: clock.now, deviceID: device
        )
    }

    private func finish(_ sessionID: Int64) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionFinishRequest, entityID: String(sessionID), params: [:],
            createdAt: clock.now, deviceID: "device-a"
        )
    }

    private func cancel(_ original: ActionRequestPayload) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionInputCancel, entityID: original.id, params: [:],
            createdAt: clock.now, deviceID: "device-a"
        )
    }

    /// The text of each bracketed paste typed, in order.
    private var pastes: [String] {
        typed.compactMap { bytes in
            guard bytes.starts(with: Array("\u{1B}[200~".utf8)) else { return nil }
            let text = String(bytes: bytes, encoding: .utf8) ?? ""
            return String(text.dropFirst("\u{1B}[200~".count).dropLast("\u{1B}[201~".count))
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

    // MARK: - PROJ-16 guards

    /// Condition (1): without the owner's Allow nothing is typed — the line
    /// is refused, not held.
    func testProj16_AnUnallowedDeviceTypesNothing() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        _ = try sidecar.setDeviceGrant(.typing, false, deviceID: "device-a", at: Date())
        let handlers = try makeHandlers()

        let line = try await handlers.handle(input(session, "Rebase onto main"))
        let wrapUp = try await handlers.handle(finish(session))

        XCTAssertEqual(line.status, .failed)
        XCTAssertEqual(line.reason, .deviceNotAllowed)
        XCTAssertEqual(wrapUp.reason, .deviceNotAllowed)
        await delivery.deliverHeld()
        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(try sidecar.heldLines().isEmpty)
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
    }

    /// Condition (0): a device not linked by a QR scan never reaches the
    /// handler — the relay fails it `device_not_linked`, nothing typed.
    func testProj16_AnUnlinkedDeviceTypesNothing() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let transport = StubHubTransport()
        let dispatcher = MobileHubCommandDispatcher()
        try makeHandlers().register(on: dispatcher)
        let processor = RelayProcessor(transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme")
        let stranger = input(session, "Delete the tests", device: "device-x")
        try await transport.save([try CloudRecordFactory.record(for: stranger, modifiedAt: Date())])

        _ = try await processor.processOnce()

        let echo = try decodeAction(try XCTUnwrap(transport.saved.last { $0.record.recordName == stranger.recordName }).record)
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .deviceNotLinked)
        XCTAssertTrue(typed.isEmpty)
    }

    /// Condition (2): while the agent works the line is held (`agent_busy`),
    /// retried on each successful state read, and goes once it stopped.
    func testProj16_AWorkingSessionHoldsTheLineUntilItStops() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let handlers = try makeHandlers()
        let action = input(session, "Also update the changelog")

        let outcome = try await handlers.handle(action)

        XCTAssertEqual(outcome.status, .held)
        XCTAssertEqual(outcome.reason, .agentBusy)
        XCTAssertTrue(typed.isEmpty)
        await delivery.deliverHeld()
        XCTAssertTrue(typed.isEmpty, "still working: still held")
        for kind: SessionSwitcherPresentation.State.Kind in [.running, .background] {
            setState(session, kind)
            await delivery.deliverHeld()
            XCTAssertTrue(typed.isEmpty, "\(kind) is not idle")
        }

        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertEqual(pastes, ["Also update the changelog"])
        XCTAssertEqual(typed.last, [0x0D], "one line, then its Return (PROJ-12)")
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action), [.applied(["delivery": .string("submitted")])])
        XCTAssertTrue(try sidecar.heldLines().isEmpty)
    }

    /// I-5: a session at a permission prompt never gets a phone line, not
    /// even the wrap-up line, however often the states are read.
    func testProj16_NeedsApprovalNeverGetsAPhoneLine() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let handlers = try makeHandlers()
        let line = input(session, "yes")

        let first = try await handlers.handle(line)
        let wrapUp = try await handlers.handle(finish(session))
        for _ in 0..<3 { await delivery.deliverHeld() }

        XCTAssertEqual(first.status, .held)
        XCTAssertEqual(first.reason, .needsApproval)
        XCTAssertEqual(wrapUp.reason, .needsApproval)
        XCTAssertTrue(typed.isEmpty, "nothing reaches a permission prompt")
        // Answered on the Mac, the agent works on: still nothing.
        setState(session, .working)
        await delivery.deliverHeld()
        XCTAssertTrue(typed.isEmpty)
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: line), [.held(.agentBusy)], "the reason change is echoed")
    }

    /// Condition (3): the owner's half-typed text holds the line before the
    /// paste — nothing is pasted next to it — and the line goes once the
    /// prompt is empty.
    func testProj16_ADraftHoldsTheLineAndNothingIsPasted() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let action = input(session, "Run the tests")

        let outcome = try await handlers.handle(action)

        XCTAssertEqual(outcome.status, .held)
        XCTAssertEqual(outcome.reason, .promptHasText)
        await delivery.deliverHeld()
        XCTAssertTrue(typed.isEmpty, "nothing pasted over the draft")

        processes[0].onOwnerInput?([0x0D])
        await delivery.deliverHeld()

        XCTAssertEqual(pastes, ["Run the tests"])
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action), [.applied(["delivery": .string("submitted")])])
    }

    /// A held line expires 24 h after the phone created it, even if the
    /// session is idle by then: nothing typed, `expired`.
    func testProj16_AHeldLineExpiresAfter24h() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let handlers = try makeHandlers()
        let action = input(session, "Ship it")
        _ = try await handlers.handle(action)

        clock.advance(SessionInputHandlers.heldLifetime + 1)
        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertTrue(typed.isEmpty)
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action).map(\.status), [.expired])
        XCTAssertTrue(try sidecar.heldLines().isEmpty)
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
    }

    /// A `session_start` brief edited on the phone is used only from a
    /// device allowed to type: otherwise the Mac's own work-on prompt goes.
    func testProj16_AnEditedBriefFromAnUnallowedDeviceIsIgnored() async throws {
        _ = try sidecar.setDeviceGrant(.typing, false, deviceID: "device-a", at: Date())
        let acme = folder.path
        let (project, target) = try await pool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return (project, try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Ship it"))
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        let sidecar = try XCTUnwrap(sidecar)
        let starts = SessionStartStopHandlers(
            dbPool: pool, workbenches: vm, terminalCenter: center,
            deviceGrant: { MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
            bringForward: { _ in }, launchPause: { _ in }
        )
        let start = ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionStart, entityID: String(target),
            params: [
                "workbench_id": .integer(project), "mode": .string("new"), "plan_first": .bool(false),
                "bring_forward": .bool(false), "brief": .string("Delete the tests")
            ],
            createdAt: Date(), deviceID: "device-a"
        )

        let outcome = try await starts.handle(start)

        XCTAssertEqual(outcome.status, .applied)
        let prompts = processes.flatMap(\.launches).map { $0.environment.last }
        XCTAssertEqual(prompts, ["WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnTargetPrompt(targetID: target, vocabulary: .current))"])
        XCTAssertFalse(prompts.contains { $0?.contains("Delete the tests") == true })
    }

    /// Revoke on the Mac fails the device's held lines at once; nothing of
    /// them is typed later.
    func testProj16_RevokeFailsHeldLines() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let handlers = try makeHandlers()
        let link = MobileLinkCenter(
            sidecar: sidecar, shares: FakeShareService(), macName: "Acme Mac", ownerUser: { "_owner-acme" }, nudge: { _ in }
        )
        link.onTypingRevoked = { [weak handlers] in handlers?.revoked(deviceID: $0) }
        let first = input(session, "One")
        let second = input(session, "Two")
        _ = try await handlers.handle(first)
        _ = try await handlers.handle(second)

        try link.setTypingAllowed(false, deviceID: "device-a")

        await handlers.echoesSettled()
        for action in [first, second] {
            XCTAssertEqual(echoes.outcomes(of: action).map(\.reason), [.deviceNotAllowed])
        }
        XCTAssertTrue(try sidecar.heldLines().isEmpty)
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertTrue(typed.isEmpty)
    }

    // MARK: - The text

    func testEmptyOrWhitespaceTextIsInvalidParams() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()

        for text in ["", "   ", "\n\t\r"] {
            let outcome = try await handlers.handle(input(session, text))
            XCTAssertEqual(outcome.reason, .invalidParams, text.debugDescription)
        }
        XCTAssertTrue(typed.isEmpty)
    }

    func testLineBreaksAndControlCharactersBecomeOneLine() async throws {
        let session = try await liveSession()
        setState(session, .stopped)

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let outcome = try await makeHandlers().handle(input(session, "  first\nsecond\r\nthird\u{1B}[2Jfourth \(family) "))

        XCTAssertEqual(outcome, .applied(["delivery": .string("submitted")]))
        XCTAssertEqual(pastes, ["first second third [2Jfourth \(family)"], "a CRLF is one space; a joiner stays")
        let line = try XCTUnwrap(pastes.first)
        XCTAssertFalse(line.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    func testTextOver4000CharactersIsInvalidParams() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()

        let long = try await handlers.handle(input(session, String(repeating: "a", count: 4001)))
        XCTAssertEqual(long.reason, .invalidParams)
        XCTAssertTrue(typed.isEmpty)

        let longest = try await handlers.handle(input(session, String(repeating: "a", count: 4000)))
        XCTAssertEqual(longest.status, .applied)
    }

    func testTheFinishRequestTypesTheFixedLine() async throws {
        let session = try await liveSession()
        setState(session, .stopped)

        let outcome = try await makeHandlers().handle(finish(session))

        XCTAssertEqual(outcome, .applied(["delivery": .string("submitted")]))
        XCTAssertEqual(pastes, ["Please wrap up: update the board, then call finish_session with a short summary."])
    }

    func testAMarkedRunWithNoTurnYetIsIdle() async throws {
        let session = try await liveSession()
        statuses[session] = SessionAgentStatus(
            sessionID: session, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: .running, live: true), at: nil, runMarked: true
        )

        let outcome = try await makeHandlers().handle(input(session, "Start with the tests"))

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(pastes, ["Start with the tests"])
    }

    /// Without hooks this run the state is not known for the current run:
    /// Finished from an earlier run does not count as idle.
    func testAFinishedStateFromAnEarlierRunIsNotIdle() async throws {
        let session = try await liveSession()
        statuses[session] = SessionAgentStatus(
            sessionID: session, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: .finished, live: true), at: nil
        )

        let outcome = try await makeHandlers().handle(input(session, "Next one"))

        XCTAssertEqual(outcome.reason, .agentBusy)
        XCTAssertTrue(typed.isEmpty)
    }

    func testAFailedStateReadHoldsTheLineAsStateUnknown() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        readsSucceed = false

        let outcome = try await makeHandlers().handle(input(session, "Go on"))

        XCTAssertEqual(outcome, .held(.stateUnknown))
        XCTAssertTrue(typed.isEmpty)
    }

    func testASessionNotRunningOrNotOnABoardFails() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()

        let unknown = try await handlers.handle(input(9999, "Hello"))
        XCTAssertEqual(unknown.reason, .notFound)
        processes[0].onExit?(0)
        XCTAssertFalse(center.liveIDs.contains(session))
        let stopped = try await handlers.handle(input(session, "Hello"))
        XCTAssertEqual(stopped.reason, .sessionNotRunning)
        XCTAssertTrue(typed.isEmpty)
    }

    // MARK: - Cancel

    func testCancelAfterDeliveryIsANoOpAndTheOriginalStaysApplied() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()
        let action = input(session, "Done already")
        let delivered = try await handlers.handle(action)

        let cancelled = try await handlers.handle(cancel(action))

        XCTAssertEqual(delivered.status, .applied)
        XCTAssertEqual(cancelled, .applied())
        await handlers.echoesSettled()
        XCTAssertTrue(echoes.outcomes(of: action).isEmpty, "the original keeps its applied echo")
    }

    func testCancelWhileHeldCancelsTheOriginal() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let handlers = try makeHandlers()
        let action = input(session, "Never mind")
        _ = try await handlers.handle(action)

        let cancelled = try await handlers.handle(cancel(action))

        XCTAssertEqual(cancelled, .applied())
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action).map(\.status), [.cancelled])
        XCTAssertEqual(echoes.outcomes(of: action).map(\.reason), [.cancelled])
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(try sidecar.heldLines().isEmpty)
    }

    // MARK: - Hub restart

    func testAHeldLineSurvivesAHubRestartAndGoesOnIdle() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let before = try makeHandlers()
        before.start()
        let action = input(session, "After the restart")
        _ = try await before.handle(action)

        before.stop()
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty, "a stopped hub holds nothing in memory")
        let after = try makeHandlers()
        after.start()
        await waitUntil { self.delivery.heldKeys(sessionID: session) == [.input(action.recordName)] }

        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertEqual(pastes, ["After the restart"])
        await after.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action), [.applied(["delivery": .string("submitted")])])
    }

    /// A line marked as being typed when the hub stopped is never typed a
    /// second time: `outcome_unknown`.
    func testALineInterruptedMidPasteIsOutcomeUnknownAfterARestart() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let before = try makeHandlers()
        let action = input(session, "Half way")
        _ = try await before.handle(action)
        before.stop()
        XCTAssertTrue(try sidecar.claimHeldLineForTyping(action.recordName))

        let after = try makeHandlers()
        after.start()
        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertTrue(typed.isEmpty)
        await after.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action).map(\.reason), [.outcomeUnknown])
    }

    /// Review focus 2: the session's row is deleted while a line is held:
    /// `session_not_running`, and the line is dropped.
    func testASessionDeletedWhileALineIsHeldFailsSessionNotRunning() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let handlers = try makeHandlers()
        let action = input(session, "Too late")
        _ = try await handlers.handle(action)

        try await pool.write { try $0.execute(sql: "DELETE FROM terminal_sessions WHERE id = ?", arguments: [session]) }
        statuses[session] = nil
        await delivery.deliverHeld()

        XCTAssertTrue(typed.isEmpty)
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action).map(\.reason), [.sessionNotRunning])
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
        XCTAssertTrue(try sidecar.heldLines().isEmpty)
    }

    /// Two lines held by their gate, wired to the states the app's way
    /// (`SessionLineDelivery.follow`): each successful read tries them once
    /// — the reads their own tries make set off nothing (it used to spin).
    func testLinesHeldByTheirGateAreNotRetriedInALoop() async throws {
        let session = try await liveSession()
        let reads = ReadCounter()
        let row = SessionAgentStateRow(
            id: session, projectID: workbenchID, title: "Ship it", agentState: "working",
            agentStateAt: SessionAgentStatus.formatStamp(Date().addingTimeInterval(60)), workbenchName: "acme"
        )
        let agentStates = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: center, interval: .seconds(3600), notifier: RecordingSessionNotifier(),
            defaults: defaults, notificationCenter: NotificationCenter()
        ) { _ in
            reads.add()
            return [row]
        }
        let lines = SessionLineDelivery(terminalCenter: center)
        lines.follow(agentStates)
        var asked = 0
        let gate: SessionLineDelivery.Gate = { _ in
            asked += 1
            return .hold
        }

        _ = await lines.deliverLine("One", key: .input("action-1"), sessionID: session, gate: gate) { _ in }
        _ = await lines.deliverLine("Two", key: .input("action-2"), sessionID: session, gate: gate) { _ in }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(asked, 2, "its own read never tries a line again")

        await agentStates.poll()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(asked, 4, "one try each per read")
        XCTAssertEqual(reads.count, 5, "two first tries, one read, two retries")
        XCTAssertTrue(typed.isEmpty)
    }

    // MARK: - Races and back-to-back lines

    func testOnlyThePhoneThatSentALineCanCancelIt() async throws {
        let session = try await liveSession()
        setState(session, .working)
        try sidecar.linkTestDevice("device-b")
        let handlers = try makeHandlers()
        let action = input(session, "Mine")
        _ = try await handlers.handle(action)
        let foreign = ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionInputCancel, entityID: action.id, params: [:],
            createdAt: clock.now, deviceID: "device-b"
        )

        let refused = try await handlers.handle(foreign)

        XCTAssertEqual(refused.reason, .deviceNotAllowed)
        XCTAssertNotNil(try sidecar.heldLine(action.recordName), "the line is still held")
        await handlers.echoesSettled()
        XCTAssertTrue(echoes.outcomes(of: action).isEmpty)
    }

    /// A cancel that lands while a held line's retry reads the states: the
    /// line is not typed, and nothing follows the `cancelled` echo.
    func testACancelDuringAnInFlightRetryTypesNothing() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let handlers = try makeHandlers()
        let action = input(session, "Never mind")
        _ = try await handlers.handle(action)
        setState(session, .stopped)
        duringRead = { [weak self] in
            guard let self else { return }
            _ = try? await handlers.handle(cancel(action))
        }

        await delivery.deliverHeld()

        XCTAssertTrue(typed.isEmpty)
        await handlers.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action).map(\.status), [.cancelled])
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
    }

    /// The hub stops while a held line's retry reads the states: the
    /// stopped hub types nothing, and the next start types it once.
    func testAStopDuringAnInFlightRetryTypesNothingAndTheNextStartTypesItOnce() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let before = try makeHandlers()
        let action = input(session, "Later")
        _ = try await before.handle(action)
        setState(session, .stopped)
        duringRead = { before.stop() }

        await delivery.deliverHeld()

        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(try sidecar.heldLine(action.recordName)?.typing, false, "left held, not half-typed")
        let after = try makeHandlers()
        after.start()
        await waitUntil { self.pastes.count == 1 }
        await delivery.deliverHeld()
        XCTAssertEqual(pastes, ["Later"])
        await after.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action), [.applied(["delivery": .string("submitted")])])
    }

    /// A quick stop and start while a retry is in flight types the line
    /// once.
    func testAQuickStopAndStartTypesTheLineOnce() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let before = try makeHandlers()
        let after = try makeHandlers()
        let action = input(session, "Once")
        _ = try await before.handle(action)
        setState(session, .stopped)
        duringRead = {
            before.stop()
            after.start()
            try? await Task.sleep(for: .milliseconds(50))
        }

        await delivery.deliverHeld()
        await waitUntil { self.pastes.count == 1 }
        await delivery.deliverHeld()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(pastes, ["Once"])
        await after.echoesSettled()
        XCTAssertEqual(echoes.outcomes(of: action), [.applied(["delivery": .string("submitted")])])
    }

    /// Back to back: right after a line was submitted, the session counts
    /// as busy until a hook reports after the submit.
    func testASecondLineWaitsForAHookAfterTheFirstWasSubmitted() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()
        let first = try await handlers.handle(input(session, "First"))
        let action = input(session, "Second")

        let second = try await handlers.handle(action)
        await delivery.deliverHeld()

        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(second, .held(.agentBusy))
        XCTAssertEqual(pastes, ["First"])
        setState(session, .stopped, at: SessionAgentStatus.formatStamp(clock.now.addingTimeInterval(1)))
        await delivery.deliverHeld()
        XCTAssertEqual(pastes, ["First", "Second"])
    }

    /// No hook after the submit: the session counts as busy for
    /// `submitSettle` only.
    func testWithoutAHookTheSecondLineGoesAfterTheSettleCap() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let handlers = try makeHandlers()
        _ = try await handlers.handle(input(session, "First"))
        _ = try await handlers.handle(input(session, "Second"))

        clock.advance(SessionInputHandlers.submitSettle - 1)
        await delivery.deliverHeld()
        XCTAssertEqual(pastes, ["First"])
        clock.advance(2)
        await delivery.deliverHeld()

        XCTAssertEqual(pastes, ["First", "Second"])
    }

    // MARK: - Through the relay

    /// The relay echoes `received`, then `held`; the line's later outcome is
    /// echoed into the same record and replaces the ledger's stored echo.
    func testTheRelayEchoesHeldThenTheLaterOutcomeAndKeepsIt() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let transport = StubHubTransport()
        let dispatcher = MobileHubCommandDispatcher()
        let handlers = try makeHandlers(lateEcho: RelayProcessor.lateEcho(transport: transport, sidecar: sidecar))
        handlers.register(on: dispatcher)
        let processor = RelayProcessor(transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme")
        let action = input(session, "Through the relay")
        try await transport.save([try CloudRecordFactory.record(for: action, modifiedAt: Date())])

        _ = try await processor.processOnce()
        setState(session, .stopped)
        await delivery.deliverHeld()
        await handlers.echoesSettled()

        let statuses = try transport.saved
            .filter { $0.record.recordName == action.recordName }
            .map { try decodeAction($0.record) }
            .map(\.status)
        XCTAssertEqual(statuses, [.pending, .received, .held, .applied])
        let stored = try XCTUnwrap(try sidecar.relayEcho(action.recordName))
        XCTAssertEqual(try JSONDecoder().decode(ActionOutcome.self, from: stored), .applied(["delivery": .string("submitted")]))
        XCTAssertEqual(pastes, ["Through the relay"])
    }
}
