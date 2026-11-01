import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Desktop on `session-host` v2 (Go hub phase 3, Task 7; spec §8 p. 4b,
/// §11): the app's lines go through the host's `Deliver` on a connection of
/// their own, the app answers its re-check, the host's delivery events drive
/// the pane's bars, and the owner's close is the host's `Stop`. The host
/// side is fake frames (`FakeSessionHostTransport`); the host's algorithm is
/// pinned by its Go tests (`internal/sessionhost/deliver_test.go`).
@MainActor
final class SessionHostV2ClientTests: XCTestCase {
    private var transports: [FakeSessionHostTransport] = []
    /// The Hello version the next transports answer with.
    private var hostVersion = SessionHostHello.protocolVersion
    private var folder: URL!
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        transports = []
        hostVersion = SessionHostHello.protocolVersion
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt v2 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queue = try TestDatabase.create()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private static let inertSignaller = ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })

    private func makeClient() -> SessionHostClient {
        SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { [weak self] _ in
            let transport = FakeSessionHostTransport()
            transport.helloVersion = self?.hostVersion ?? SessionHostHello.protocolVersion
            self?.transports.append(transport)
            return transport
        })
    }

    private func row(kind: TerminalSession.Kind = .claude) throws -> TerminalSession {
        try queue.write { d in
            try d.execute(sql: "INSERT OR IGNORE INTO projects (id, name, folder_path) VALUES (1, 'acme', ?)", arguments: [folder.path])
            return try TerminalSessionQueries.create(d, .init(
                projectID: 1, kind: kind, title: "s", folderPath: folder.path,
                claudeSessionID: kind == .claude ? UUID().uuidString.lowercased() : nil
            ))
        }
    }

    /// A center whose session runs in the (fake) host, launched as launch 3.
    private func hostedSession(
        kind: TerminalSession.Kind = .claude,
        codex: CodexLaunchArgs? = nil
    ) async throws -> (TerminalCenter, TerminalSession, HostedTerminalSession, FakeSessionHostTransport) {
        let client = makeClient()
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        let center = TerminalCenter(signaller: Self.inertSignaller)
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in false }
        center.sessionHost = client
        let s = try row(kind: kind)
        center.start(s, fresh: true, codex: codex)
        let hosted = try XCTUnwrap(center.process(for: s.id) as? HostedTerminalSession)
        await hosted.connecting?.value
        let transport = try XCTUnwrap(transports.last)
        let key = try XCTUnwrap(hosted.key)
        transport.push(.json(.launched, SessionHostSessionInfo(
            row: key.row, run: key.run, pid: 5150, startedAtMs: 1, exited: false, code: nil, launch: 3
        )))
        return (center, s, hosted, transport)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// The transport a delivery opened, once its Deliver went out.
    private func deliverTransport() async throws -> FakeSessionHostTransport {
        await waitUntil { transports.contains { !$0.sent(.deliver).isEmpty } }
        return try XCTUnwrap(transports.first { !$0.sent(.deliver).isEmpty })
    }

    private func deliverID(_ transport: FakeSessionHostTransport) throws -> String {
        try XCTUnwrap(transport.sent(.deliver).first).decoded(DeliverRequest.self).id
    }

    // MARK: - Hello

    /// Every connection says Hello v2: the control one, a session's and a
    /// delivery's. A delivery to a v1 host — it has no Deliver — types
    /// nothing and reads as no session.
    func testHelloV2() async throws {
        XCTAssertEqual(SessionHostHello.protocolVersion, 2)
        let (center, s, _, transport) = try await hostedSession()
        let control = try XCTUnwrap(transports.first)
        for connection in [control, transport] {
            let hello = try XCTUnwrap(connection.sent(.hello).first).decoded(SessionHostHello.self)
            XCTAssertEqual(hello.version, 2)
        }

        hostVersion = 1
        let delivery = await center.deliver("x", sessionID: s.id) { true }
        XCTAssertEqual(delivery, .noSession)
        let refused = try XCTUnwrap(transports.last)
        XCTAssertEqual(try XCTUnwrap(refused.sent(.hello).first).decoded(SessionHostHello.self).version, 2)
        XCTAssertTrue(refused.closed, "the delivery's connection closes with it")
    }

    // MARK: - Deliver

    /// The host's re-check is answered from the app's state: `fresh` from
    /// the re-read, `can_submit` from the hooks and the permission prompt
    /// (`SessionLineDelivery`'s gates, PROJ-12), `answers_dialog` from the
    /// dialog the states show. The request names the run's row, run and
    /// launch and carries the pre-check; its Delivered decides the outcome.
    func testDeliverAnswersTheRecheckWithSessionControlState() async throws {
        let (center, s, hosted, _) = try await hostedSession()
        let lines = SessionLineDelivery(terminalCenter: center)
        lines.hasHookState = { _ in true }
        lines.needsApproval = { _ in false }
        var reads = 0
        lines.refreshStates = {
            reads += 1
            return reads == 1 // the read after the pause fails
        }
        var dialog = false
        center.inputAnswersDialog = { _ in dialog }

        let sending = Task { await lines.deliverLine("Ask #7 answered", key: .ask(7), sessionID: s.id) { _ in } }
        let connection = try await deliverTransport()
        let request = try XCTUnwrap(connection.sent(.deliver).first).decoded(DeliverRequest.self)
        let key = try XCTUnwrap(hosted.key)
        XCTAssertEqual(request.row, key.row)
        XCTAssertEqual(request.run, key.run)
        XCTAssertEqual(request.launch, 3)
        XCTAssertEqual(request.text, "Ask #7 answered")
        XCTAssertTrue(request.submitIf, "the hooks vouch for this run before the paste")
        XCTAssertFalse(request.holdIfPromptText)
        XCTAssertFalse(request.keepLineBreaks)
        XCTAssertEqual(request.settleMs, 500, "an answer's pause")

        dialog = true
        connection.push(.json(.deliverCheck, DeliverCheck(id: request.id)))
        await waitUntil { !connection.sent(.deliverCheckReply).isEmpty }
        let reply = try XCTUnwrap(connection.sent(.deliverCheckReply).first).decoded(DeliverCheckReply.self)
        XCTAssertEqual(reply, DeliverCheckReply(id: request.id, fresh: false, canSubmit: true, answersDialog: true))

        connection.push(.json(.delivered, DeliveredMessage(id: request.id, outcome: "typed", reason: "check_failed")))
        let delivery = await sending.value
        XCTAssertEqual(delivery, .typed)
        XCTAssertTrue(connection.closed)
    }

    /// A DeliverCheck or a Delivered of another request on the connection
    /// is not this delivery's; a permission prompt the states show makes
    /// `can_submit` false.
    func testOnlyItsOwnCheckAndAnswerCount() async throws {
        let (center, s, _, _) = try await hostedSession()
        let lines = SessionLineDelivery(terminalCenter: center)
        lines.hasHookState = { _ in true }
        var approval = false
        lines.needsApproval = { _ in approval }
        lines.refreshStates = { true }

        let sending = Task { await lines.deliverLine("line", key: .review(1), sessionID: s.id) { _ in } }
        let connection = try await deliverTransport()
        let id = try deliverID(connection)
        connection.push(.json(.deliverCheck, DeliverCheck(id: "other")))
        connection.push(.json(.delivered, DeliveredMessage(id: "other", outcome: "submitted")))
        await Task.yield()
        XCTAssertTrue(connection.sent(.deliverCheckReply).isEmpty)

        approval = true
        connection.push(.json(.deliverCheck, DeliverCheck(id: id)))
        await waitUntil { !connection.sent(.deliverCheckReply).isEmpty }
        let reply = try XCTUnwrap(connection.sent(.deliverCheckReply).first).decoded(DeliverCheckReply.self)
        XCTAssertTrue(reply.fresh)
        XCTAssertFalse(reply.canSubmit, "a permission prompt after the pause")
        connection.push(.json(.delivered, DeliveredMessage(id: id, outcome: "submitted")))
        let delivery = await sending.value
        XCTAssertEqual(delivery, .submitted)
    }

    /// The host's `no_paste_mode`: nothing was typed, so the line goes to
    /// the clipboard — Desktop is a desktop host — with today's hint.
    func testNoPasteModeCopiesToThePasteboard() async throws {
        let (center, s, _, _) = try await hostedSession()
        var copied: [String] = []
        center.copyToClipboard = { copied.append($0) }

        let sending = Task { await center.deliver("Address it\nplease", sessionID: s.id, keepingLineBreaks: false) { true } }
        let connection = try await deliverTransport()
        connection.push(.json(.delivered, DeliveredMessage(id: try deliverID(connection), outcome: "no_paste_mode")))
        let delivery = await sending.value

        XCTAssertEqual(delivery, .copied)
        XCTAssertEqual(copied, ["Address itplease"], "cleaned as the paste would have been")
        XCTAssertTrue(center.clipboardHints.contains(s.id))
    }

    /// A phone line asks the host to hold it over text in the prompt
    /// (PROJ-16); the host's `held` is a held line, nothing typed.
    func testAPhoneLineIsHeldByTheHostOverPromptText() async throws {
        let (center, s, _, _) = try await hostedSession()
        let lines = SessionLineDelivery(terminalCenter: center)
        lines.refreshStates = { true }

        let sending = Task { await lines.deliverLine("from the phone", key: .input("a-1"), sessionID: s.id) { _ in } }
        let connection = try await deliverTransport()
        let request = try XCTUnwrap(connection.sent(.deliver).first).decoded(DeliverRequest.self)
        XCTAssertTrue(request.holdIfPromptText)
        XCTAssertTrue(request.keepFormat)
        connection.push(.json(.delivered, DeliveredMessage(id: request.id, outcome: "held", reason: "prompt_has_text")))
        let delivery = await sending.value

        XCTAssertEqual(delivery, .held)
        XCTAssertEqual(lines.heldKeys(sessionID: s.id), [.input("a-1")], "tried again on the next read")
    }

    // MARK: - Delivery events

    /// The host's events on the pane's connection drive its bars: a line
    /// left typed shows "press Return" (sharing the prompt when beside
    /// text); the next paste clears the bars. Another run's events change
    /// nothing.
    func testDeliveryEventsShowPaneHints() async throws {
        let (center, s, hosted, transport) = try await hostedSession()
        let key = try XCTUnwrap(hosted.key)

        transport.push(.json(.deliveryEvent, SessionHostDeliveryEvent(row: key.row, run: "another", kind: .leftTyped)))
        XCTAssertFalse(center.pasteHints.contains(s.id), "another run's event")

        transport.push(.json(.deliveryEvent, SessionHostDeliveryEvent(row: key.row, run: key.run, kind: .pasted)))
        transport.push(.json(.deliveryEvent, SessionHostDeliveryEvent(row: key.row, run: key.run, kind: .leftTyped, besideText: true)))
        XCTAssertTrue(center.pasteHints.contains(s.id))
        XCTAssertTrue(center.sharedPrompts.contains(s.id))
        XCTAssertTrue(center.promptHoldsText(s.id), "the phone's pre-check sees the line left typed")

        transport.push(.json(.deliveryEvent, SessionHostDeliveryEvent(row: key.row, run: key.run, kind: .pasted)))
        XCTAssertFalse(center.pasteHints.contains(s.id))
        XCTAssertFalse(center.sharedPrompts.contains(s.id))

        // An ask's answer shows its own bar, not the paste one.
        center.showAnswerHint(.typed, sessionID: s.id)
        transport.push(.json(.deliveryEvent, SessionHostDeliveryEvent(row: key.row, run: key.run, kind: .leftTyped)))
        XCTAssertFalse(center.pasteHints.contains(s.id))
        XCTAssertEqual(center.answerHints[s.id], .typed)
    }

    // MARK: - Stop and exit

    /// PROJ-18: an exit that followed the host's Stop — the owner stopped
    /// the session — is the app's, so no cleanup follows; a natural exit is
    /// the session's own.
    func testRequestedExitIsClosedByAppAndCleansNothing() async throws {
        for requested in [true, false] {
            transports = []
            let (center, s, _, transport) = try await hostedSession()
            var exits: [(Int64, Int32?, Bool)] = []
            center.onSessionExit = { exits.append(($0, $1, $2)) }

            transport.push(.json(.exit, SessionHostExit(code: 0, requested: requested)))

            XCTAssertEqual(exits.count, 1)
            XCTAssertEqual(exits.first?.0, s.id)
            XCTAssertEqual(exits.first?.2, requested, requested ? "the owner's stop" : "a natural exit")
        }
    }

    /// The owner's close is the host's Stop for the run's row, run and
    /// launch; the app signals nothing.
    func testCloseSendsTheHostsStop() async throws {
        var signals: [(pid_t, Int32)] = []
        let client = makeClient()
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        let center = TerminalCenter(signaller: ProcessGroupSignaller(
            signal: { signals.append(($0, $1)) }, isAlive: { _ in true }, sleep: { _ in }
        ))
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in false }
        center.sessionHost = client
        let s = try row()
        center.start(s, fresh: true)
        let hosted = try XCTUnwrap(center.process(for: s.id) as? HostedTerminalSession)
        await hosted.connecting?.value
        let key = try XCTUnwrap(hosted.key)
        try XCTUnwrap(transports.last).push(.json(.launched, SessionHostSessionInfo(
            row: key.row, run: key.run, pid: 5150, startedAtMs: 1, exited: false, code: nil, launch: 3
        )))
        let control = try XCTUnwrap(transports.first)

        await center.close(sessionID: s.id)

        let stop = try XCTUnwrap(control.sent(.stop).first).decoded(SessionHostStopRequest.self)
        XCTAssertEqual(stop, SessionHostStopRequest(row: key.row, run: key.run, launch: 3))
        XCTAssertTrue(signals.isEmpty, "the host signals, not the app")
        XCTAssertNil(center.states[s.id])
    }

    /// The host types with the run's agent profile: a Codex row's launch
    /// says so, a shell's names none.
    func testALaunchNamesItsAgent() async throws {
        let (_, _, _, codex) = try await hostedSession(
            kind: .codex, codex: CodexLaunchArgs(binary: "/Users/example/bin/codex", pathPrepend: "", args: [])
        )
        let codexLaunch = try XCTUnwrap(codex.sent(.launch).first).decoded(SessionHostLaunchRequest.self)
        XCTAssertEqual(codexLaunch.agent, "codex")

        transports = []
        let (_, _, _, shell) = try await hostedSession(kind: .shell)
        let shellLaunch = try XCTUnwrap(shell.sent(.launch).first).decoded(SessionHostLaunchRequest.self)
        XCTAssertEqual(shellLaunch.agent, "")
    }

    /// The dialog hint goes on the pane's own (bound) connection.
    func testPromptHintsGoToTheRunsHost() async throws {
        let (center, s, hosted, transport) = try await hostedSession()
        center.inputAnswersDialog = { _ in true }

        center.syncPromptHints()

        let hint = try XCTUnwrap(transport.sent(.promptHint).first).decoded(SessionHostPromptHint.self)
        XCTAssertEqual(hint, SessionHostPromptHint(row: s.id, run: try XCTUnwrap(hosted.key).run, dialog: true))
    }
}
