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

    private func makeModel(_ sessionID: Int64) throws -> WorkchatModel {
        let clock = try XCTUnwrap(clock)
        let control = SessionControl(
            dbPool: pool, terminalCenter: center, lineDelivery: delivery,
            status: { [weak self] in self?.statuses[$0] },
            now: { clock.now }
        )
        return WorkchatModel(sessionID: sessionID, control: control, lineDelivery: delivery) { clock.now }
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

    func testSendWhileWorkingQueues() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "Also add the teammate fixture"

        await model.send()

        let line = try XCTUnwrap(model.outgoing.first)
        XCTAssertEqual(line.state, .queued)
        XCTAssertEqual(typedText, "", "nothing typed into a busy agent")
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
        setState(session, .working)
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

    /// Review Focus 2: the session ends while a line waits. The bubble says
    /// it was not sent and the text comes back to the field.
    func testQueuedLineAfterSessionEndsReturnsToField() async throws {
        let session = try await liveSession()
        setState(session, .working)
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
        setState(session, .working)
        let model = try makeModel(session)
        model.draft = "First"
        await model.send()
        model.draft = "Second, still typing"

        processes[0].onExit?(0)
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

    /// Codex writes no permission rows: no card.
    func testNoPermissionCardForCodexSession() async throws {
        let session = try await liveSession(kind: .codex)
        setState(session, .working)
        let model = try makeModel(session)

        await model.refreshPermission()

        XCTAssertNil(model.permission)
    }
}
