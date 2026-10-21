import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// `WorkchatModel`: the Workchat composer's lines go through
/// `SessionLineDelivery` behind `SessionControl.lineCheck` (PROJ-16's gate,
/// no device grant at the Mac), and Stop through its interrupt guard (#711).
@MainActor
final class WorkchatModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var delivery: SessionLineDelivery!
    private var statuses: [Int64: SessionAgentStatus] = [:]
    private var clock: LinkTestClock!
    private var workbenchID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt workchat \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        statuses = [:]
        clock = LinkTestClock(Date())
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
        center.transcriptExists = { _ in true }
        delivery = SessionLineDelivery(terminalCenter: center)
        delivery.refreshStates = { true }
        let deliveryClock = try XCTUnwrap(clock)
        delivery.now = { deliveryClock.now }
        delivery.needsApproval = { [weak self] in self?.statuses[$0]?.state.kind == .needsApproval }
        delivery.hasHookState = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var typedText: String { String(bytes: processes.flatMap(\.inputs).joined(), encoding: .utf8) ?? "" }

    private func makeControl() throws -> SessionControl {
        let clock = try XCTUnwrap(clock)
        return SessionControl(
            dbPool: pool, terminalCenter: center, lineDelivery: delivery,
            status: { [weak self] in self?.statuses[$0] },
            now: { clock.now }
        )
    }

    private func makeModel(_ sessionID: Int64, control: (any WorkchatControl)? = nil) throws -> WorkchatModel {
        let clock = try XCTUnwrap(clock)
        let control = try control ?? makeControl()
        return WorkchatModel(sessionID: sessionID, control: control, lineDelivery: delivery, kind: .claude) { clock.now }
    }

    /// Lets one test make the permission read, the answer or the interrupt
    /// fail or wait; each call not scripted goes to the real control.
    private final class ScriptedControl: WorkchatControl {
        let base: SessionControl
        var pending: ((Int64) async throws -> SessionControl.PermissionPrompt?)?
        var answer: (() async throws -> SessionControl.PermissionAnswer)?
        var interrupt: (() async throws -> SessionControl.InterruptResult)?
        private(set) var answers = 0

        init(base: SessionControl) {
            self.base = base
        }

        func lineCheck(_ sessionID: Int64) -> SessionControl.LineCheck {
            base.lineCheck(sessionID)
        }

        func workchatLineCheck(_ sessionID: Int64) -> SessionControl.LineCheck {
            base.workchatLineCheck(sessionID)
        }

        func isWorking(_ sessionID: Int64) -> Bool {
            base.isWorking(sessionID)
        }

        func interrupt(_ sessionID: Int64) async throws -> SessionControl.InterruptResult {
            if let interrupt { return try await interrupt() }
            return try await base.interrupt(sessionID)
        }

        func pendingPermission(_ sessionID: Int64) async throws -> SessionControl.PermissionPrompt? {
            if let pending { return try await pending(sessionID) }
            return try await base.pendingPermission(sessionID)
        }

        func answerPermission(requestID: Int64, sessionID: Int64, allow: Bool, decidedBy: String) async throws
            -> SessionControl.PermissionAnswer {
            answers += 1
            if let answer { return try await answer() }
            return try await base.answerPermission(requestID: requestID, sessionID: sessionID, allow: allow, decidedBy: decidedBy)
        }
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "disk I/O error" }
    }

    /// A one-time suspension the test releases: the first `wait` parks
    /// until `release`; later ones pass straight through.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var reached = false

        func wait() async {
            guard !reached else { return }
            reached = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }

        /// Yields until a call parks here (bounded).
        func untilReached() async {
            for _ in 0..<1_000 where !reached { await Task.yield() }
        }
    }

    private func liveSession(kind: TerminalSession.Kind = .claude) async throws -> Int64 {
        let acme = folder.path
        let session = try await pool.write { db -> TerminalSession in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: kind, title: "Ship it", folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        workbenchID = try XCTUnwrap(session.projectID)
        // A Codex session needs its binary to start; the permission read
        // does not care whether it runs.
        guard kind == .claude else { return session.id }
        center.start(session, fresh: true)
        XCTAssertTrue(center.liveIDs.contains(session.id))
        return session.id
    }

    private func setState(_ sessionID: Int64, _ kind: SessionSwitcherPresentation.State.Kind) {
        statuses[sessionID] = SessionAgentStatus(
            sessionID: sessionID, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: kind, live: true), at: SessionAgentStatus.formatStamp(clock.now)
        )
    }

    private func owner(_ text: String, after seconds: TimeInterval) -> SessionFeedEntry {
        SessionFeedEntry(id: UUID().uuidString, kind: "owner", at: clock.now.addingTimeInterval(seconds), text: text)
    }

    // MARK: - Send

    func testSendIdleSubmits() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "  Fix the flaky test\n"

        await model.send()

        XCTAssertEqual(model.draft, "", "the field clears")
        XCTAssertEqual(model.outgoing.map(\.text), ["Fix the flaky test"], "trimmed")
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Fix the flaky test"))
        XCTAssertTrue(typedText.contains("\r"), "submitted with Return")
    }

    func testSendWhileWorkingSubmitsAtOnce() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "Also add the teammate fixture"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.state, .sent)
        XCTAssertTrue(line.sentWhileBusy)
        XCTAssertTrue(typedText.contains("Also add the teammate fixture"))
    }

    func testTwoLinesWhileBusyGoInOrder() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "First"
        await model.send()
        model.draft = "Second"
        await model.send()

        XCTAssertEqual(model.outgoing.map(\.state), [.sent, .queued], "no hook since line 1: line 2 waits")
        // The turn's hook reports; the next state read sends line 2.
        clock.advance(1)
        setState(session, .working)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.map(\.state), [.sent, .sent])
        let first = try XCTUnwrap(typedText.range(of: "First"))
        let second = try XCTUnwrap(typedText.range(of: "Second"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertEqual(typedText.components(separatedBy: "First").count, 2, "once")
        XCTAssertEqual(typedText.components(separatedBy: "Second").count, 2, "once")
        XCTAssertFalse(typedText.contains("FirstSecond"))
    }

    func testQueuedCaptionFollowsTheAgentKind() {
        XCTAssertEqual(WorkchatOutgoingBubble.queuedCaption(holdsUntilIdle: true), "Queued · sends when the agent stops ·")
        XCTAssertEqual(WorkchatOutgoingBubble.queuedCaption(holdsUntilIdle: false), "Queued · sends in a moment ·")
    }

    func testUnknownKindKeepsTheBusyHold() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(sessionID: session, control: try makeControl(), lineDelivery: delivery) { clock.now }
        model.draft = "Hello"

        await model.send()

        XCTAssertTrue(model.holdsUntilIdle)
        XCTAssertEqual(model.outgoing.first?.state, .queued)
    }

    func testBusyLineEchoAfterTwoMinutesStillMatches() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "Also add the fixture"
        await model.send()
        let delivered = try XCTUnwrap(model.outgoing.first?.deliveredAt)

        model.reconcile(with: [SessionFeedEntry(
            id: "late", kind: "owner", at: delivered.addingTimeInterval(150), text: "Also add the fixture"
        )])

        XCTAssertTrue(model.outgoing.isEmpty)
    }

    func testIdleLineEchoWindowUnchanged() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Also add the fixture"
        await model.send()
        let delivered = try XCTUnwrap(model.outgoing.first?.deliveredAt)

        model.reconcile(with: [SessionFeedEntry(
            id: "late", kind: "owner", at: delivered.addingTimeInterval(150), text: "Also add the fixture"
        )])

        XCTAssertEqual(model.outgoing.count, 1, "an idle line's echo past the window stays a bubble")
    }

    func testSendWhileWorkingHoldsOnCodex() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let clock = try XCTUnwrap(clock)
        let model = WorkchatModel(
            sessionID: session, control: try makeControl(), lineDelivery: delivery, kind: .codex
        ) { clock.now }
        model.draft = "Also add the fixture"

        await model.send()

        XCTAssertEqual(model.outgoing.first?.state, .queued)
    }

    func testSendWhileApprovalPendingQueues() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Also add the teammate fixture"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.state, .queued)
        XCTAssertEqual(typedText, "", "nothing typed over a permission prompt")
        XCTAssertEqual(delivery.heldKeys(sessionID: session), [.workchat(line.id)])

        // The agent stops: the next state read sends it.
        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Also add the teammate fixture"))
    }

    /// Review Focus 1: the owner's half-typed text sits in the terminal
    /// prompt; the Workchat line is held, never appended to that draft.
    func testLineHeldWhilePromptHoldsText() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))
        let model = try makeModel(session)
        model.draft = "Run the linter"

        await model.send()

        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertFalse(typedText.contains("Run the linter"), "never typed after the owner's draft")
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .queued, "still held while the draft is there")
        XCTAssertFalse(typedText.contains("Run the linter"))
    }

    func testCancelDropsHeldLine() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Never mind"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)

        model.cancel(id)

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty)
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertEqual(typedText, "", "a cancelled line is never typed")
    }

    /// Cancel on a line that is not queued — on its first try, or sent —
    /// changes nothing (final review m7).
    func testCancelOnALineNotQueuedIsANoOp() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        let gate = Gate()
        delivery.refreshStates = { await gate.wait(); return true }
        model.draft = "Hold on"
        let sending = Task { await model.send() }
        await gate.untilReached()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        XCTAssertEqual(model.outgoing.first?.state, .sending)

        model.cancel(id)
        XCTAssertEqual(model.outgoing.map(\.id), [id], "a line on its first try stays")
        gate.release()
        await sending.value
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        XCTAssertEqual(delivery.heldKeys(sessionID: session), [.workchat(id)], "nothing was dropped from the queue")

        delivery.refreshStates = { true }
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        model.cancel(id)
        XCTAssertEqual(model.outgoing.map(\.state), [.sent], "a sent line stays")
    }

    /// A queued line whose retry is under way is out of the queue:
    /// `dropHeld` finds nothing and the line stays (final review m7).
    func testCancelKeepsALineWhoseRetryIsUnderWay() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Run it"
        await model.send()
        let id = try XCTUnwrap(model.outgoing.first?.id)
        XCTAssertEqual(model.outgoing.first?.state, .queued)

        let gate = Gate()
        delivery.refreshStates = { await gate.wait(); return true }
        setState(session, .stopped)
        let retry = Task { await delivery.deliverHeld() }
        await gate.untilReached()
        XCTAssertTrue(delivery.heldKeys(sessionID: session).isEmpty, "taken out for its retry")

        model.cancel(id)
        XCTAssertEqual(model.outgoing.map(\.id), [id], "nothing was dropped: the line stays")
        gate.release()
        await retry.value
        XCTAssertEqual(model.outgoing.first?.state, .sent)
    }

    /// Review Focus 2: the session ends while a line waits. The bubble says
    /// it was not sent and the text comes back to the field.
    func testQueuedLineAfterSessionEndsReturnsToField() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Add the fixture"
        await model.send()
        XCTAssertEqual(model.draft, "")

        processes[0].onExit?(0)
        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "Add the fixture", "back in the field")
        XCTAssertEqual(typedText, "")
    }

    /// The field holds a newer draft: it is kept, the bubble still says the
    /// line was not sent.
    func testNotSentLineKeepsANewerDraft() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "First"
        await model.send()
        model.draft = "Second, still typing"

        processes[0].onExit?(0)
        statuses[session] = nil
        await delivery.deliverHeld()

        XCTAssertEqual(model.outgoing.first?.state, .notSent)
        XCTAssertEqual(model.draft, "Second, still typing")
    }

    func testEmptyLineNotSent() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "  \n\t "

        await model.send()

        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(typedText, "")
    }

    // MARK: - Reconcile

    func testReconcileRemovesEchoedLine() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Ship it"
        await model.send()

        model.reconcile(with: [owner("Ship it", after: -10), owner("Something else", after: 1)])
        XCTAssertEqual(model.outgoing.count, 1, "an older identical line is not its echo")

        model.reconcile(with: [owner("Ship it", after: -10), owner("Ship it", after: 1)])
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// Two identical lines: one echo stands for one of them only.
    func testReconcileMatchesOneEchoPerLine() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Again"
        await model.send()
        clock.advance(31)
        setState(session, .stopped)
        model.draft = "Again"
        await model.send()
        XCTAssertEqual(model.outgoing.map(\.state), [.sent, .sent])

        let echo = owner("Again", after: 1)
        model.reconcile(with: [echo])
        XCTAssertEqual(model.outgoing.count, 1)
        model.reconcile(with: [echo, owner("Again", after: 2)])
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// A Workchat line keeps its line breaks (owner ask #421, PROJ-12
    /// amended): the typed paste, the bubble and the echo agree.
    func testMultilineDraftKeepsLineBreaks() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Fix the test\r\nand run it \n"

        await model.send()

        XCTAssertEqual(model.outgoing.map(\.text), ["Fix the test\nand run it"])
        XCTAssertEqual(model.outgoing.first?.state, .sent)
        XCTAssertTrue(typedText.contains("Fix the test\nand run it"), "typed with its line break: \(typedText)")
        model.reconcile(with: [owner("Fix the test\nand run it", after: 1)])
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    func testWhitespaceOnlyDraftNotSent() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = " \n\t\n "
        await model.send()
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(typedText, "")
    }

    /// The pane was off screen past the window: an echo dated in time still
    /// takes the line when the feed is read at last.
    func testLateReconcileStillMatchesTimelyEcho() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "Ship it"
        await model.send()
        let echo = owner("Ship it", after: 2)

        clock.advance(120)
        model.reconcile(with: [echo])

        XCTAssertTrue(model.outgoing.isEmpty)
    }

    /// A feed read holding the echo landed while the line was still on its
    /// way: settling matches it against that read.
    func testEchoSeenWhileSendingReconcilesOnSettle() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Later"
        await model.send()
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        model.reconcile(with: [owner("Later", after: 1)])
        XCTAssertEqual(model.outgoing.count, 1, "a queued line has no echo yet")

        setState(session, .stopped)
        await delivery.deliverHeld()

        XCTAssertTrue(model.outgoing.isEmpty, "the echo already read takes it")
    }

    /// The same text typed in the terminal while the line sat queued is
    /// dated before its delivery: it is not the line's echo (final review m1).
    func testOwnerEntryWhileQueuedIsNotTheEcho() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let model = try makeModel(session)
        model.draft = "Ship it"
        await model.send()
        XCTAssertEqual(model.outgoing.first?.state, .queued)
        let typedMeanwhile = owner("Ship it", after: 5)

        clock.advance(20)
        setState(session, .stopped)
        await delivery.deliverHeld()
        XCTAssertEqual(model.outgoing.first?.state, .sent)

        model.reconcile(with: [typedMeanwhile])
        XCTAssertEqual(model.outgoing.count, 1, "the bubble stays")

        model.reconcile(with: [typedMeanwhile, owner("Ship it", after: -1)])
        XCTAssertTrue(model.outgoing.isEmpty, "an echo stamped just before deliveredAt still takes it")
    }

    /// No echo within `echoWindow` (a `/clear`, say): the line stays as a
    /// plain local bubble, and a late identical entry does not take it.
    func testReconcileKeepsLineWithoutEchoPastWindow() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let model = try makeModel(session)
        model.draft = "/clear"
        await model.send()

        clock.advance(WorkchatOutgoing.echoWindow + 1)
        model.reconcile(with: [owner("/clear", after: 0)])

        XCTAssertEqual(model.outgoing.map(\.text), ["/clear"])
    }

    // MARK: - Stop

    func testStopRefusedWithPendingRequest() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let workbench = workbenchID
        let created = SessionAgentStatus.formatStamp(clock.now)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests
                        (terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
                    VALUES (?, ?, 'Bash', 'make test', 0, 'pending', ?)
                    """,
                arguments: [session, workbench, created]
            )
        }
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .awaitingApproval)
        XCTAssertTrue(processes.flatMap(\.inputs).isEmpty, "no Esc over a prompt")
    }

    func testStopSendsEscWhileWorking() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(processes.flatMap(\.inputs), [[0x1B]])
    }

    /// Refusals say why (final review m6); the result is still returned.
    func testStopRefusedWithPendingRequestSaysWhy() async throws {
        let session = try await liveSession()
        setState(session, .working)
        try await insertRequest(session, summary: "make test")
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .awaitingApproval)
        XCTAssertEqual(model.stopError, "A permission prompt is open — answer it on the card or in the terminal")
    }

    func testStopOnASessionNotRunningSaysWhy() async throws {
        let session = try await liveSession()
        setState(session, .working)
        processes[0].onExit?(0)
        let model = try makeModel(session)

        let result = await model.stop()

        XCTAssertEqual(result, .notRunning)
        XCTAssertEqual(model.stopError, "The session is not running")
    }

    /// A failed check sets `stopError`; the next Stop that goes clears it.
    func testStopErrorClearsOnTheNextSuccess() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let control = ScriptedControl(base: try makeControl())
        control.interrupt = { throw Failure() }
        let model = try makeModel(session, control: control)

        let failed = await model.stop()
        XCTAssertEqual(failed, .notWorking)
        XCTAssertEqual(model.stopError, "Could not check for a permission prompt: disk I/O error")

        control.interrupt = nil
        let sent = await model.stop()
        XCTAssertEqual(sent, .sent)
        XCTAssertNil(model.stopError)
    }

    // MARK: - Permission

    @discardableResult
    private func insertRequest(_ sessionID: Int64, summary: String = "gh pr merge 340 --merge", clipped: Bool = false) async throws -> Int64 {
        let workbench = workbenchID
        let created = SessionAgentStatus.formatStamp(clock.now)
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests
                        (terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
                    VALUES (?, ?, 'Bash', ?, ?, 'pending', ?)
                    """,
                arguments: [sessionID, workbench, summary, clipped, created]
            )
            return db.lastInsertedRowID
        }
    }

    private func storedRequest(_ id: Int64) async throws -> (status: String, decidedBy: String?) {
        try await pool.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT status, decided_by FROM permission_requests WHERE id = ?", arguments: [id]))
            return (row["status"], row["decided_by"])
        }
    }

    func testPermissionCardShownForPendingRow() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        XCTAssertNil(model.permission)

        await model.refreshPermission()

        let card = try XCTUnwrap(model.permission)
        XCTAssertEqual(card.id, id)
        XCTAssertEqual(card.toolName, "Bash")
        XCTAssertEqual(card.summary, "gh pr merge 340 --merge")
        XCTAssertNil(card.allowBlock, "Allow is offered")
    }

    func testAllowAppliesAndClears() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()

        await model.answer(allow: true)

        XCTAssertNil(model.permission)
        XCTAssertNil(model.permissionError)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "allowed")
        XCTAssertEqual(stored.decidedBy, "Mac")
        XCTAssertTrue(processes.flatMap(\.inputs).isEmpty, "only the hook decides: nothing typed")
    }

    /// Review Focus 5: the phone (or the terminal) answered first. The
    /// Workchat's answer changes nothing and the card leaves.
    func testAnsweredElsewhereRemovesCard() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()
        XCTAssertNotNil(model.permission)
        try await pool.write { db in
            try db.execute(sql: "UPDATE permission_requests SET status = 'denied', decided_by = 'iPhone' WHERE id = ?", arguments: [id])
        }

        await model.answer(allow: true)

        XCTAssertNil(model.permission, "the card leaves")
        XCTAssertNil(model.permissionError)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "denied", "the first answer stands")
        XCTAssertEqual(stored.decidedBy, "iPhone")

        // A state change alone also drops a card answered elsewhere.
        try await insertRequest(session, summary: "make test")
        await model.refreshPermission()
        let next = try XCTUnwrap(model.permission)
        try await pool.write { db in
            try db.execute(sql: "UPDATE permission_requests SET status = 'allowed' WHERE id = ?", arguments: [next.id])
        }
        await model.refreshPermission()
        XCTAssertNil(model.permission)
    }

    func testAllowBlockedKeepsDenyOnly() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session, summary: "rm -rf build && …", clipped: true)
        let model = try makeModel(session)
        await model.refreshPermission()
        XCTAssertEqual(model.permission?.allowBlock, .clipped, "Deny and Show in Terminal only")

        await model.answer(allow: true)

        XCTAssertEqual(model.permission?.id, id, "the card stays")
        XCTAssertEqual(model.permission?.allowBlock, .clipped)
        let pending = try await storedRequest(id)
        XCTAssertEqual(pending.status, "pending", "an allow is refused")

        await model.answer(allow: false)

        XCTAssertNil(model.permission)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "denied", "a deny always may")
    }

    /// The session ended under the card: it leaves, the row is not written.
    func testAnswerAfterSessionEndsClears() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()
        processes[0].onExit?(0)

        await model.answer(allow: true)

        XCTAssertNil(model.permission)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "pending")
    }

    /// Prompt B arrives right after A was answered here, and its hook sets
    /// Needs approval again within one state poll: the kind never changes,
    /// but the hook stamp does, and the pane's read key with it.
    func testNextPromptShowsAfterHookStampChanges() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        try await insertRequest(session)
        let model = try makeModel(session)
        await model.refreshPermission()
        let before = WorkchatModel.PermissionReadKey(statuses[session])

        await model.answer(allow: true)
        XCTAssertNil(model.permission, "B's row is not written yet")

        let second = try await insertRequest(session, summary: "make test")
        clock.advance(1)
        setState(session, .needsApproval)
        let after = WorkchatModel.PermissionReadKey(statuses[session])
        XCTAssertEqual(before.kind, after.kind)
        XCTAssertNotEqual(before, after, "a new hook stamp re-runs the read")

        await model.refreshPermission()
        XCTAssertEqual(model.permission?.id, second)
    }

    /// A failed read before the first card: no card, the error kept for
    /// the pane's caption (final review M4).
    func testFailedPermissionReadWithoutACardKeepsTheError() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let control = ScriptedControl(base: try makeControl())
        control.pending = { _ in throw Failure() }
        let model = try makeModel(session, control: control)

        await model.refreshPermission()

        XCTAssertNil(model.permission)
        XCTAssertEqual(model.permissionError, "Could not read the permission prompt: disk I/O error")
    }

    /// An answer that fails keeps the card and says why (final review m7).
    func testFailedAnswerKeepsTheCard() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let control = ScriptedControl(base: try makeControl())
        let model = try makeModel(session, control: control)
        await model.refreshPermission()
        control.answer = { throw Failure() }

        await model.answer(allow: true)

        XCTAssertEqual(model.permission?.id, id, "the card stays")
        XCTAssertEqual(model.permissionError, "Could not answer the prompt: disk I/O error")
        XCTAssertFalse(model.answering)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "pending")
    }

    /// A second Allow or Deny while one is on its way is ignored.
    func testSecondAnswerWhileAnsweringIsIgnored() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let control = ScriptedControl(base: try makeControl())
        let model = try makeModel(session, control: control)
        await model.refreshPermission()
        let gate = Gate()
        let base = control.base
        control.answer = {
            await gate.wait()
            return try await base.answerPermission(requestID: id, sessionID: session, allow: true, decidedBy: WorkchatModel.decidedBy)
        }
        let first = Task { await model.answer(allow: true) }
        await gate.untilReached()
        XCTAssertTrue(model.answering)

        await model.answer(allow: false)

        XCTAssertEqual(control.answers, 1, "the second answer never reached the control")
        gate.release()
        await first.value
        XCTAssertFalse(model.answering)
        XCTAssertNil(model.permission)
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "allowed", "the first answer, the only one")
    }

    /// A read that started before an answer and finishes after it is
    /// stale: the answered card does not come back (final review m7).
    func testReadFinishingAfterAnAnswerDoesNotBringTheCardBack() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let id = try await insertRequest(session)
        let control = ScriptedControl(base: try makeControl())
        let model = try makeModel(session, control: control)
        await model.refreshPermission()
        let stale = try XCTUnwrap(model.permission)
        XCTAssertEqual(stale.id, id)

        let gate = Gate()
        var reads = 0
        let base = control.base
        control.pending = { sessionID in
            reads += 1
            // The first read waits past the answer; the answer's own read is real.
            guard reads == 1 else { return try await base.pendingPermission(sessionID) }
            await gate.wait()
            return stale
        }
        let read = Task { await model.refreshPermission() }
        await gate.untilReached()

        await model.answer(allow: true)
        XCTAssertNil(model.permission)
        gate.release()
        await read.value

        XCTAssertNil(model.permission, "the old read is dropped")
        let stored = try await storedRequest(id)
        XCTAssertEqual(stored.status, "allowed")
    }

    /// Codex writes no permission rows: no card.
    func testNoPermissionCardForCodexSession() async throws {
        let session = try await liveSession(kind: .codex)
        setState(session, .working)
        let model = try makeModel(session)

        await model.refreshPermission()

        XCTAssertNil(model.permission)
    }
}
