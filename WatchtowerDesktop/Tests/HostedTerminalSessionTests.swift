import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore

/// A session host connection that records what goes out and lets the test
/// push what comes in. With `autoReply` it answers Hello, List and Forget
/// the way the host does.
@MainActor
final class FakeSessionHostTransport: SessionHostTransport {
    private(set) var sent: [SessionHostFrame] = []
    private(set) var opened = false
    private(set) var closed = false
    var openError: (any Error)?
    var autoReply = true
    var listed: [SessionHostSessionInfo] = []
    /// How many Forgets are refused (as for a run not reaped yet) before
    /// they are answered.
    var refusedForgets = 0
    private var onFrame: ((SessionHostFrame) -> Void)?
    private var onClose: (() -> Void)?

    func open(onFrame: @escaping (SessionHostFrame) -> Void, onClose: @escaping () -> Void) async throws {
        if let openError { throw openError }
        opened = true
        self.onFrame = onFrame
        self.onClose = onClose
    }

    func send(_ frame: SessionHostFrame) {
        sent.append(frame)
        guard autoReply else { return }
        switch frame.type {
        case .hello: push(.json(.helloOK, SessionHostHello(version: 1, pid: 99)))
        case .list: push(.json(.listed, SessionHostListResponse(sessions: listed)))
        case .forget where refusedForgets > 0:
            refusedForgets -= 1
            push(.json(.error, SessionHostErrorMessage(message: "forget: session is running")))
        case .forget: push(SessionHostFrame(type: .forgot))
        default: break
        }
    }

    func close() { closed = true }

    func push(_ frame: SessionHostFrame) { onFrame?(frame) }
    func hangUp() { onClose?() }

    func sent(_ type: SessionHostFrameType) -> [SessionHostFrame] { sent.filter { $0.type == type } }
}

@MainActor
final class HostedTerminalSessionTests: XCTestCase {
    private var transports: [FakeSessionHostTransport] = []
    /// Failures for the next opens, in order.
    private var openErrors: [(any Error)?] = []
    private var spawned: [(String, String)] = []
    private var signals: [(pid_t, Int32)] = []

    override func setUp() {
        super.setUp()
        transports = []
        openErrors = []
        spawned = []
        signals = []
    }

    private func makeClient(cli: String? = "/opt/watchtower") -> SessionHostClient {
        let client = SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { cli }, makeTransport: { [weak self] _ in
            let transport = FakeSessionHostTransport()
            if let self, !openErrors.isEmpty { transport.openError = openErrors.removeFirst() }
            self?.transports.append(transport)
            return transport
        })
        client.spawnHost = { [weak self] cli, socket in self?.spawned.append((cli, socket)) }
        client.sleep = { _ in }
        client.signalGroup = { [weak self] pid, sig in self?.signals.append((pid, sig)) }
        return client
    }

    /// A client already holding its control connection, the first transport.
    private func connectedClient() async -> SessionHostClient {
        let client = makeClient()
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        return client
    }

    /// A session's connection is the transport after the control one.
    private func startedSession(
        _ launch: TerminalLaunch = TerminalLaunch(executable: "/bin/zsh", args: ["-l"], currentDirectory: "/tmp/acme",
                                                  environment: ["WATCHTOWER_TERMINAL_SESSION_ID=7"], rowID: 7)
    ) async throws -> (HostedTerminalSession, FakeSessionHostTransport) {
        let session = HostedTerminalSession(client: await connectedClient())
        session.start(launch)
        await session.connecting?.value
        XCTAssertEqual(transports.count, 2)
        let transport = try XCTUnwrap(transports.last)
        return (session, transport)
    }

    private func launched(_ transport: FakeSessionHostTransport, session: HostedTerminalSession, pid: Int = 5150) throws {
        let key = try XCTUnwrap(session.key)
        transport.push(.json(.launched, SessionHostSessionInfo(row: key.row, run: key.run, pid: pid, startedAtMs: 1, exited: false, code: nil)))
    }

    private func terminalView(_ session: HostedTerminalSession) throws -> PalettedTerminalView {
        try XCTUnwrap(session.view as? PalettedTerminalView)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testStartSendsLaunchWithRowEnvAndSize() async throws {
        let (session, transport) = try await startedSession()
        XCTAssertEqual(transport.sent.map(\.type), [.hello, .launch])
        XCTAssertEqual(try transport.sent[0].decoded(SessionHostHello.self).version, 1)
        let request = try transport.sent[1].decoded(SessionHostLaunchRequest.self)
        XCTAssertEqual(request.row, 7)
        XCTAssertEqual(request.run, session.key?.run)
        XCTAssertNotNil(UUID(uuidString: request.run))
        XCTAssertEqual(request.executable, "/bin/zsh")
        XCTAssertEqual(request.args, ["-l"])
        XCTAssertEqual(request.cwd, "/tmp/acme")
        XCTAssertTrue(request.env.contains("TERM=xterm-256color"))
        XCTAssertTrue(request.env.contains("SHELL=/bin/zsh"))
        XCTAssertTrue(request.env.contains("WATCHTOWER_TERMINAL_SESSION_ID=7"))
        let terminal = try terminalView(session).getTerminal()
        XCTAssertEqual(request.cols, terminal.cols)
        XCTAssertEqual(request.rows, terminal.rows)
        XCTAssertGreaterThan(request.cols, 0)
    }

    func testARelaunchUsesANewRunOnANewConnection() async throws {
        let (session, first) = try await startedSession()
        let firstRun = try XCTUnwrap(session.key?.run)
        first.push(.json(.exit, SessionHostExit(code: 0)))
        session.start(TerminalLaunch(executable: "/bin/zsh", args: ["-l"], currentDirectory: "/tmp/acme", rowID: 7))
        await session.connecting?.value
        let second = try XCTUnwrap(transports.last)
        XCTAssertFalse(second === first)
        let request = try second.sent[1].decoded(SessionHostLaunchRequest.self)
        XCTAssertNotEqual(request.run, firstRun)
    }

    func testOutputIsFedAndOwnerInputGoesToHost() async throws {
        let (session, transport) = try await startedSession()
        var ownerInputs: [[UInt8]] = []
        session.onOwnerInput = { ownerInputs.append($0) }
        try launched(transport, session: session)
        XCTAssertEqual(session.pid, 5150)

        transport.push(SessionHostFrame(type: .output, payload: Array("x".utf8)))
        let view = try terminalView(session)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "x")

        session.sendInput([0x61])
        XCTAssertEqual(transport.sent(.input).last?.payload, [0x61])
        XCTAssertTrue(ownerInputs.isEmpty)

        view.send(source: view, data: [0x62][...])
        XCTAssertEqual(transport.sent(.input).last?.payload, [0x62])
        XCTAssertEqual(ownerInputs, [[0x62]])
    }

    func testInputOverOneMiBIsSplit() async throws {
        let (session, transport) = try await startedSession()
        session.sendInput([UInt8](repeating: 0x61, count: SessionHostFrame.maxPayload + 10))
        XCTAssertEqual(transport.sent(.input).map(\.payload.count), [SessionHostFrame.maxPayload, 10])
    }

    func testAResizeGoesToTheHost() async throws {
        let (session, transport) = try await startedSession()
        let view = try terminalView(session)
        view.setFrameSize(NSSize(width: 400, height: 200))
        let resize = try XCTUnwrap(transport.sent(.resize).last).decoded(SessionHostResize.self)
        XCTAssertEqual(resize, SessionHostResize(cols: view.getTerminal().cols, rows: view.getTerminal().rows))
        let count = transport.sent(.resize).count
        view.setFrameSize(NSSize(width: 400, height: 200))
        XCTAssertEqual(transport.sent(.resize).count, count, "an unchanged grid sends nothing")
    }

    func testExitFrameReportsCodeAndForgets() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        transport.push(.json(.exit, SessionHostExit(code: 3)))
        XCTAssertEqual(exits, [3])
        XCTAssertTrue(transport.closed)
        // Output after Exit is ignored.
        transport.push(SessionHostFrame(type: .output, payload: Array("late".utf8)))
        XCTAssertEqual(try terminalView(session).getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "")

        let control = transports[0]
        await waitUntil { !control.sent(.forget).isEmpty }
        let forget = try XCTUnwrap(control.sent(.forget).first).decoded(SessionHostAttachRequest.self)
        XCTAssertEqual(forget, session.key)
    }

    func testAnExitBySignalReportsNil() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        transport.push(SessionHostFrame(type: .exit, payload: Array(#"{"code":null}"#.utf8)))
        XCTAssertEqual(exits, [nil])
    }

    func testAConnectionLostBeforeLaunchedReportsNilExit() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        transport.hangUp()
        transport.hangUp()
        XCTAssertEqual(exits, [nil])
        XCTAssertNil(session.recovering, "an unbound run is not looked up")
        XCTAssertTrue(transports[0].sent(.list).isEmpty)
    }

    /// The host no longer lists the run: it is gone, nothing to forget.
    func testTransportCloseReportsNilExit() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        transport.hangUp()
        await session.recovering?.value
        XCTAssertEqual(exits, [nil])
        XCTAssertEqual(transports[0].sent(.list).count, 1)
        XCTAssertTrue(transports[0].sent(.forget).isEmpty, "a lost connection forgets nothing")
    }

    /// A dropped connection (a slow reader, a takeover) of a run still
    /// going reattaches it on a fresh connection; nothing is reported.
    func testADroppedRunStillRunningIsReattached() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        let key = try XCTUnwrap(session.key)
        let info = SessionHostSessionInfo(row: key.row, run: key.run, pid: 5150, startedAtMs: 1, exited: false, code: nil)
        transports[0].listed = [info]
        transport.hangUp()
        await session.recovering?.value
        await session.connecting?.value
        XCTAssertTrue(exits.isEmpty)
        let fresh = try XCTUnwrap(transports.last)
        XCTAssertFalse(fresh === transport)
        XCTAssertEqual(fresh.sent.map(\.type), [.hello, .attach])
        XCTAssertEqual(try fresh.sent[1].decoded(SessionHostAttachRequest.self), key)
        fresh.push(.json(.attached, info))
        fresh.push(SessionHostFrame(type: .output, payload: Array("y".utf8)))
        XCTAssertEqual(try terminalView(session).getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "y")

        // The reattach's Attached does not restore the retry (two windows
        // taking one run from each other must not loop): the next drop
        // ends the run.
        fresh.hangUp()
        XCTAssertEqual(exits, [nil])
        XCTAssertEqual(transports[0].sent(.list).count, 1)
    }

    /// Another app instance attached the run: the pane says so and lets go,
    /// with no reattach, no exit and no forget; closing it signals nothing.
    func testATakenOverRunIsNeitherReattachedNorReported() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        let key = try XCTUnwrap(session.key)
        transports[0].listed = [SessionHostSessionInfo(row: key.row, run: key.run, pid: 5150, startedAtMs: 1, exited: false, code: nil)]

        transport.push(.json(.error, SessionHostErrorMessage(message: SessionHostErrorMessage.takenOver)))
        transport.hangUp()

        XCTAssertNil(session.recovering, "a taken-over run is not looked up")
        XCTAssertTrue(exits.isEmpty)
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(transports.count, 2, "no reattach connection")
        XCTAssertTrue(transports[0].sent(.list).isEmpty)
        XCTAssertTrue(transports[0].sent(.forget).isEmpty)
        XCTAssertEqual(session.pid, 0)
        let terminal = try terminalView(session).getTerminal()
        let text = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        XCTAssertTrue(text.contains("[Watchtower] Another Watchtower window took this session over."), text)
        session.sendInput([0x61])
        XCTAssertTrue(transport.sent(.input).isEmpty)
    }

    /// A second drop before the reattach was answered is the run's end.
    func testASecondDropOfOneBindingReportsNilExit() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        let key = try XCTUnwrap(session.key)
        transports[0].listed = [SessionHostSessionInfo(row: key.row, run: key.run, pid: 5150, startedAtMs: 1, exited: false, code: nil)]
        transport.hangUp()
        await session.recovering?.value
        await session.connecting?.value
        let fresh = try XCTUnwrap(transports.last)
        fresh.hangUp()
        XCTAssertEqual(exits, [nil])
        XCTAssertEqual(transports[0].sent(.list).count, 1)
    }

    func testADroppedRunThatExitedReportsItsCodeAndForgets() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        let key = try XCTUnwrap(session.key)
        transports[0].listed = [SessionHostSessionInfo(row: key.row, run: key.run, pid: 5150, startedAtMs: 1, exited: true, code: 2)]
        transport.hangUp()
        await session.recovering?.value
        XCTAssertEqual(exits, [2])
        let control = transports[0]
        await waitUntil { !control.sent(.forget).isEmpty }
        XCTAssertEqual(try control.sent(.forget).first?.decoded(SessionHostAttachRequest.self), key)
    }

    /// The replay re-runs a device-attributes query: its answer must not
    /// reach the program; once the replay is in, the terminal answers again.
    func testTerminalRepliesDuringTheReplayAreDropped() async throws {
        let client = await connectedClient()
        let session = HostedTerminalSession(client: client)
        var release: (() -> Void)?
        session.sleep = { _ in await withCheckedContinuation { release = $0.resume } }
        let info = SessionHostSessionInfo(row: 4, run: "run-a", pid: 777, startedAtMs: 1, exited: false, code: nil)
        session.attach(info)
        await session.connecting?.value
        let transport = try XCTUnwrap(transports.last)
        transport.push(.json(.attached, info))
        transport.push(SessionHostFrame(type: .output, payload: Array("\u{1b}[c".utf8)))
        XCTAssertTrue(transport.sent(.input).isEmpty, "a replayed query is not answered")
        session.sendInput([0x61])
        XCTAssertEqual(transport.sent(.input).map(\.payload), [[0x61]], "the app's own input still goes")

        await waitUntil { release != nil }
        release?()
        let view = try terminalView(session)
        await waitUntil { !view.dropsTerminalReplies }
        transport.push(SessionHostFrame(type: .output, payload: Array("\u{1b}[c".utf8)))
        XCTAssertEqual(transport.sent(.input).count, 2, "a live query is answered")
    }

    func testALaunchRefusedByTheHostEndsTheRun() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        transport.push(.json(.error, SessionHostErrorMessage(message: "fork/exec /bin/zsh: no such file")))
        XCTAssertEqual(exits, [nil])
        XCTAssertTrue(transport.closed)
    }

    func testAnUnreachableHostEndsTheRun() async throws {
        let session = HostedTerminalSession(client: await connectedClient())
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        openErrors = [CocoaError(.fileNoSuchFile)]
        session.start(TerminalLaunch(executable: "/bin/zsh", args: ["-l"], currentDirectory: "/tmp", rowID: 1))
        await session.connecting?.value
        XCTAssertEqual(exits, [nil])
        let terminal = try terminalView(session).getTerminal()
        let text = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined()
        XCTAssertTrue(text.contains("[Watchtower] could not reach the session host"), text)
    }

    func testReattachedSessionReportsBracketedPaste() async throws {
        let session = HostedTerminalSession(client: await connectedClient())
        var release: (() -> Void)?
        session.sleep = { _ in await withCheckedContinuation { release = $0.resume } }
        let info = SessionHostSessionInfo(row: 4, run: "run-a", pid: 777, startedAtMs: 1, exited: false, code: nil)
        session.attach(info)
        await session.connecting?.value
        let transport = try XCTUnwrap(transports.last)
        XCTAssertEqual(transport.sent.map(\.type), [.hello, .attach])
        XCTAssertEqual(try transport.sent[1].decoded(SessionHostAttachRequest.self), SessionHostAttachRequest(row: 4, run: "run-a"))
        XCTAssertEqual(session.pid, 777)
        XCTAssertFalse(session.bracketedPasteMode)
        transport.push(.json(.attached, info))
        // One column narrower at once; the real size only after the
        // replay's quiet period, so the child sees a real change.
        let terminal = try terminalView(session).getTerminal()
        let resizes = { try transport.sent(.resize).map { try $0.decoded(SessionHostResize.self) } }
        XCTAssertEqual(try resizes(), [SessionHostResize(cols: terminal.cols - 1, rows: terminal.rows)])
        transport.push(SessionHostFrame(type: .output, payload: Array("\u{1b}[?2004h".utf8)))
        XCTAssertTrue(session.bracketedPasteMode)

        await waitUntil { release != nil }
        XCTAssertEqual(try resizes().count, 1, "the real size waits for the quiet period")
        release?()
        await waitUntil { transport.sent(.resize).count == 2 }
        XCTAssertEqual(try resizes(), [
            SessionHostResize(cols: terminal.cols - 1, rows: terminal.rows),
            SessionHostResize(cols: terminal.cols, rows: terminal.rows)
        ])
    }

    /// An exited run's pid may be reused: the session never holds it, so a
    /// close before the Exit arrives signals nothing.
    func testAttachingAnExitedRunHoldsNoPid() async throws {
        let session = HostedTerminalSession(client: await connectedClient())
        let info = SessionHostSessionInfo(row: 4, run: "run-a", pid: 777, startedAtMs: 1, exited: true, code: 0)
        session.attach(info)
        XCTAssertEqual(session.pid, 0)
        await session.connecting?.value
        let transport = try XCTUnwrap(transports.last)
        transport.push(.json(.attached, info))
        XCTAssertEqual(session.pid, 0)
        session.detach()
        XCTAssertTrue(signals.isEmpty)
    }

    func testAttachingAnExitedRunReportsItsExitAndForgets() async throws {
        let session = HostedTerminalSession(client: await connectedClient())
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        let info = SessionHostSessionInfo(row: 4, run: "run-a", pid: 777, startedAtMs: 1, exited: true, code: 0)
        session.attach(info)
        await session.connecting?.value
        let transport = try XCTUnwrap(transports.last)
        transport.push(.json(.attached, info))
        transport.push(.json(.exit, SessionHostExit(code: 0)))
        XCTAssertEqual(exits, [0])
        XCTAssertTrue(transport.sent(.resize).isEmpty)
        let control = transports[0]
        await waitUntil { !control.sent(.forget).isEmpty }
        XCTAssertEqual(try control.sent(.forget).first?.decoded(SessionHostAttachRequest.self), SessionHostAttachRequest(row: 4, run: "run-a"))
    }

    func testDetachFromHostNeverReportsExit() async throws {
        let (session, transport) = try await startedSession()
        var exits: [Int32?] = []
        session.onExit = { exits.append($0) }
        try launched(transport, session: session)
        session.detachFromHost()
        XCTAssertTrue(transport.closed)
        XCTAssertNil(session.onExit)
        transport.push(.json(.exit, SessionHostExit(code: 0)))
        transport.hangUp()
        XCTAssertTrue(exits.isEmpty)
        XCTAssertTrue(transport.sent(.input).isEmpty)
        session.sendInput([0x61])
        XCTAssertTrue(transport.sent(.input).isEmpty)
    }

    /// Closed before the host reported the pid: the app could not hang the
    /// group up, so the session does once the pid arrives.
    func testDetachBeforeLaunchedHangsUpOnceThePidArrives() async throws {
        let (session, transport) = try await startedSession()
        session.detach()
        try launched(transport, session: session, pid: 4321)
        XCTAssertEqual(signals.map(\.0), [4321])
        XCTAssertEqual(signals.map(\.1), [SIGHUP])
    }

    // MARK: SessionHostClient

    func testEnsureRunningConnectsWithoutStartingAHost() async {
        let client = makeClient()
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        XCTAssertTrue(spawned.isEmpty)
        XCTAssertEqual(transports.first?.sent.map(\.type), [.hello])
        let again = await client.ensureRunning()
        XCTAssertTrue(again)
        XCTAssertEqual(transports.count, 1, "a connected client opens nothing new")
    }

    func testEnsureRunningStartsTheHostWhenNoneAnswers() async {
        let client = makeClient()
        openErrors = [CocoaError(.fileNoSuchFile), CocoaError(.fileNoSuchFile)]
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        XCTAssertEqual(spawned.map(\.0), ["/opt/watchtower"])
        XCTAssertEqual(spawned.map(\.1), ["/tmp/wt-test.sock"])
        XCTAssertEqual(transports.count, 3)
    }

    func testEnsureRunningFailsWithoutACLI() async {
        let client = makeClient(cli: nil)
        openErrors = [CocoaError(.fileNoSuchFile)]
        let running = await client.ensureRunning()
        XCTAssertFalse(running)
        XCTAssertTrue(spawned.isEmpty)
    }

    func testListDecodesTheHostSessions() async throws {
        let client = makeClient()
        _ = await client.ensureRunning()
        let info = SessionHostSessionInfo(row: 2, run: "r", pid: 10, startedAtMs: 5, exited: true, code: nil)
        transports[0].listed = [info]
        let sessions = try await client.list()
        XCTAssertEqual(sessions, [info])
    }

    func testAHostErrorFailsTheRequest() async throws {
        let client = makeClient()
        _ = await client.ensureRunning()
        let control = transports[0]
        control.autoReply = false
        async let listing = client.list()
        await waitUntil { !control.sent(.list).isEmpty }
        control.push(.json(.error, SessionHostErrorMessage(message: "nope")))
        do {
            _ = try await listing
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SessionHostError, .host("nope"))
        }
    }

    func testALostControlConnectionReconnectsOnTheNextRequest() async throws {
        let client = makeClient()
        _ = await client.ensureRunning()
        transports[0].hangUp()
        _ = try await client.list()
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[1].sent.map(\.type), [.hello, .list])
    }
}
