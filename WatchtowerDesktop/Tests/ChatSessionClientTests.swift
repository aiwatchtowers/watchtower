import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The session client over a scripted process. The process saves the turn
/// (`ai session --persist`, played by `FakeChatSessionProcess` with the test
/// database); the client sends it, waits for `started` and streams it.
@MainActor
final class ChatSessionClientTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var path: String!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        (dbPool, path) = try TestDatabase.createPool()
        conversationID = try dbPool.write { d in try TestDatabase.insertChatConversation(d) }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func config() -> ChatSessionConfig {
        ChatSessionConfig(conversationID: conversationID, provider: "claude", model: nil)
    }

    /// A persisting fake on the test database.
    private func persistingFake() -> FakeChatSessionProcess {
        FakeChatSessionProcess(arguments: ChatSessionClient.arguments(for: config(), dbPath: path, leaseOwnerID: "launch-1"),
                               db: dbPool)
    }

    private func makeClient(
        launchImmediately: Bool = true,
        startedTimeout: Duration = ChatSessionClient.defaultStartedTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ spawn: @escaping () throws -> any ChatSessionProcess
    ) -> ChatSessionClient {
        ChatSessionClient(config: config(), spawn: spawn, clock: Date.init, launchImmediately: launchImmediately,
                          startedTimeout: startedTimeout, sleep: sleep)
    }

    private func command(_ text: String = "hi", turnID: String = "t1") -> ChatTurnCommand {
        ChatTurnCommand(turnID: turnID, text: text, attachments: [], replay: false,
                        start: ChatTurnStart(mode: .send, titleText: text))
    }

    private func assistant(_ turnID: String = "t1") throws -> ChatMessageRecord? {
        let conv = conversationID
        return try dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: """
                SELECT * FROM chat_messages WHERE conversation_id = ? AND role = 'assistant' AND turn_id = ?
                """, arguments: [conv, turnID])
        }
    }

    func testArgumentsCarryOnlyFlags() {
        var cfg = ChatSessionConfig(conversationID: 7, provider: "claude", model: "model-b")
        XCTAssertEqual(ChatSessionClient.arguments(for: cfg, dbPath: "/tmp/w.db", leaseOwnerID: "launch-1"),
                       ["ai", "session", "--conversation", "7", "--provider", "claude", "--surface", "main",
                        "--model", "model-b", "--db-path", "/tmp/w.db",
                        "--persist", "--lease-owner", "desktop", "--lease-owner-id", "launch-1"])
        cfg.model = nil
        XCTAssertEqual(ChatSessionClient.arguments(for: cfg, dbPath: nil, leaseOwnerID: "launch-1"),
                       ["ai", "session", "--conversation", "7", "--provider", "claude", "--surface", "main",
                        "--persist", "--lease-owner", "desktop", "--lease-owner-id", "launch-1"])
    }

    /// CHAT-04 (Swift half): the session argv is built from the config
    /// alone — the turn text and attachment paths exist only in the stdin
    /// command. No session resumes a stored provider session (#604 G11,
    /// ask #571): the argv never carries `--resume`.
    /// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
    func testChat04SessionArgvNeverCarriesContent() throws {
        let cfg = ChatSessionConfig(conversationID: 7, provider: "claude", model: nil)
        let argv = ChatSessionClient.arguments(for: cfg, dbPath: "/tmp/w.db", leaseOwnerID: "launch-1")
        XCTAssertFalse(argv.contains("--resume"))
        let args = argv.joined(separator: " ")
        let turn = ChatCommand.turn(ChatTurnCommand(
            turnID: "t", text: "SECRET-TEXT",
            attachments: [ChatCommandAttachment(path: "/tmp/SECRET.pdf", mime: "application/pdf", name: "SECRET.pdf")],
            replay: false))
        XCTAssertFalse(args.contains("SECRET"))
        XCTAssertTrue(try turn.jsonLine().contains("SECRET-TEXT"))
        XCTAssertTrue(try turn.jsonLine().contains("/tmp/SECRET.pdf"))
    }

    /// CHAT-04 end to end through the client: the argv handed to the process
    /// factory stays content-free after a turn went out.
    /// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
    func testChat04TurnContentTravelsOnlyOnStdin() async {
        let args = ChatSessionClient.arguments(for: config(), dbPath: "/tmp/w.db", leaseOwnerID: "launch-1")
        let fake = FakeChatSessionProcess(arguments: args)
        let client = makeClient { fake }
        let starting = Task {
            await client.startTurn(ChatTurnCommand(
                turnID: "t1", text: "SECRET-TEXT",
                attachments: [ChatCommandAttachment(path: "/tmp/SECRET.png", mime: "image/png", name: "SECRET.png")],
                replay: false))
        }
        await untilTurn { !fake.sent.isEmpty }
        XCTAssertFalse(fake.arguments.joined(separator: " ").contains("SECRET"))
        XCTAssertEqual(fake.turns.first?.text, "SECRET-TEXT")
        XCTAssertEqual(fake.turns.first?.attachments.map(\.path), ["/tmp/SECRET.png"])
        starting.cancel()
        fake.exit(status: 0)
        _ = await starting.value
    }

    /// The turn line carries what the session writes (mode, files, title
    /// source, the screen block), never on argv.
    func testTurnLineCarriesTheStartFields() throws {
        let line = try ChatCommand.turn(ChatTurnCommand(
            turnID: "t", text: "Use skill x\nhi", attachments: [], replay: false,
            start: ChatTurnStart(mode: .send, attachmentIDs: [4], quotes: [9], titleText: "hi", screen: "[SCREEN]")))
            .jsonLine()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "send")
        XCTAssertEqual(json["attachment_ids"] as? [Int], [4])
        XCTAssertEqual(json["quotes"] as? [Int], [9])
        XCTAssertEqual(json["title_text"] as? String, "hi")
        XCTAssertEqual(json["screen"] as? String, "[SCREEN]")
        let regenerateTurn = ChatCommand.turn(ChatTurnCommand(
            turnID: "t", text: "", attachments: [], replay: false, start: ChatTurnStart(mode: .regenerate, parentID: 12)))
        let regenerate = try regenerateTurn.jsonLine()
        XCTAssertTrue(regenerate.contains(#""parent_id":12"#))
        XCTAssertFalse(regenerate.contains("title_text"))
    }

    func testSessionArgumentsCarryProjectIDOnlyWhenSet() {
        var config = ChatSessionConfig(conversationID: 7, provider: "claude", model: nil)
        XCTAssertFalse(ChatSessionClient.arguments(for: config, dbPath: "/tmp/w.db", leaseOwnerID: "l")
            .contains("--project-id"))
        config.projectID = 42
        let args = ChatSessionClient.arguments(for: config, dbPath: "/tmp/w.db", leaseOwnerID: "l")
        let flag = args.firstIndex(of: "--project-id")
        XCTAssertEqual(flag.map { args[$0 + 1] }, "42")
    }

    func testConfigCompatibility() {
        let base = ChatSessionConfig(conversationID: 1, provider: "claude", model: "m")
        XCTAssertTrue(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: "m")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 2, provider: "claude", model: "m")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "codex", model: "m")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: nil)))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: "m",
                                                                 surface: "target")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: "m",
                                                                 projectID: 3)),
                       "moving a chat into a project needs a session with the project prompt")
    }

    func testTurnStartsStreamsAndReportsCompletion() async throws {
        let fake = persistingFake()
        let client = makeClient { fake }
        var finished: [Int64] = []
        client.onTurnFinished = { finished.append($0) }
        let outcome = await client.startTurn(command())
        guard case let .started(started) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fake.turns.map(\.text), ["hi"])
        XCTAssertEqual(client.liveTurn?.messageID, started.assistantMessageID)
        XCTAssertTrue(client.isBusy)

        fake.emit(.textDelta(turnID: "t1", text: "Hello"))
        fake.emit(.turnDone(turnID: "t1", status: .complete, sessionID: "s1"))
        await untilTurn { !client.isBusy }
        XCTAssertEqual(try assistant()?.text, "Hello")
        XCTAssertEqual(try assistant()?.status, "complete")
        XCTAssertEqual(finished, [conversationID])
    }

    /// While a turn runs, a second start is refused (never two turns on one session).
    func testStartTurnWhileBusyIsRefused() async {
        let fake = persistingFake()
        let client = makeClient { fake }
        _ = await client.startTurn(command("one"))
        let second = await client.startTurn(command("two", turnID: "t2"))
        guard case .failed = second else { return XCTFail("\(second)") }
        XCTAssertEqual(fake.turns.map(\.text), ["one"])
    }

    /// The phone's turn holds the chat: `refused`, nothing written.
    func testRefusedWhileTheHubHoldsTheLease() async throws {
        let conv = conversationID
        let nowMS = ChatLease.milliseconds(Date())
        try await dbPool.write { d in
            _ = try ChatLeaseQueries.claim(d, ChatLease(conversationID: conv, owner: .hub, ownerID: "hub-1", turnID: "p1",
                                                        startedAtMS: nowMS, heartbeatAtMS: nowMS), nowMS: nowMS)
        }
        let fake = persistingFake()
        let client = makeClient { fake }
        let outcome = await client.startTurn(command())
        XCTAssertEqual(outcome, .refused(ChatRefusal(turnID: "t1", reason: "conversation_busy", holder: "hub")))
        XCTAssertFalse(client.isBusy)
        XCTAssertNil(try assistant())
        XCTAssertTrue(fake.turns.isEmpty)
    }

    /// A spawn failure never throws at the caller: the turn fails, nothing written.
    func testSpawnFailureFailsTheStart() async throws {
        struct Boom: Error {}
        let client = makeClient { throw Boom() }
        XCTAssertFalse(client.isAlive)
        XCTAssertEqual(client.startupError?.code, .providerUnavailable)
        let outcome = await client.startTurn(command())
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(try assistant())
    }

    func testSendFailureFailsTheStart() async throws {
        struct PipeClosed: Error {}
        let fake = persistingFake()
        fake.sendError = PipeClosed()
        let client = makeClient { fake }
        let outcome = await client.startTurn(command())
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(client.isBusy)
        XCTAssertNil(try assistant())
    }

    /// A process silent past `startedTimeout`: the start gives up, the
    /// process is retired so nothing of the turn runs after.
    func testSilentProcessGivesUpAndIsRetired() async {
        let fake = FakeChatSessionProcess(arguments: [])
        let gate = SleepGate()
        let client = makeClient(sleep: { _ in try await gate.wait() }, { fake })
        let starting = Task { await client.startTurn(self.command()) }
        await gate.untilWaiting()
        gate.open()
        let outcome = await starting.value
        XCTAssertEqual(outcome, .failed(ChatSessionError(turnID: "t1", code: .sessionLost,
                                                         message: ChatSessionClient.silentMessage, retryable: true)))
        XCTAssertFalse(client.isAlive)
        await untilTurn { fake.terminated }
    }

    func testProcessDeathAfterStartedReportsTheLostTurn() async throws {
        let fake = persistingFake()
        let client = makeClient { fake }
        var lost: [String] = []
        client.onTurnLost = { _, turnID in lost.append(turnID) }
        _ = await client.startTurn(command())
        fake.emit(.textDelta(turnID: "t1", text: "half"))
        await untilTurn { client.liveTurn?.fullText == "half" }
        fake.exit(status: 9)
        await untilTurn { !client.isAlive }
        XCTAssertEqual(lost, ["t1"], "the Mac sends chat.recover for it")
        XCTAssertEqual(try assistant()?.text, "half", "what streamed was saved as it came")
        XCTAssertEqual(try assistant()?.status, "partial")
    }

    /// A process that dies before `started`: nothing was written; the
    /// start fails with the exit message.
    func testProcessDeathBeforeStartedFailsTheStart() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        let starting = Task { await client.startTurn(self.command()) }
        await untilTurn { !fake.sent.isEmpty }
        fake.exit(status: 2, stderr: "panic: boom")
        let outcome = await starting.value
        guard case let .failed(error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(error.code, .sessionLost)
        XCTAssertEqual(error.message, "The chat session ended unexpectedly (exit status 2). panic: boom")
    }

    /// A crash without a terminal event surfaces the exit status + stderr tail.
    func testUnexpectedExitSurfacesStatusAndStderr() async throws {
        let fake = persistingFake()
        let client = makeClient { fake }
        _ = await client.startTurn(command())
        fake.emit(.textDelta(turnID: "t1", text: "half"))
        fake.exit(status: 2, stderr: "panic: boom\n\ngoroutine 1\n")
        await untilTurn { !client.isAlive }
        XCTAssertEqual(client.exitError?.code, .sessionLost)
        XCTAssertEqual(client.exitError?.message,
                       "The chat session ended unexpectedly (exit status 2). panic: boom goroutine 1")
        XCTAssertEqual(client.driver.lastSessionError, client.exitError)
        let next = await client.startTurn(command(turnID: "t2"))
        guard case .failed = next else { return XCTFail("\(next)") }
    }

    /// An exit we asked for (close/SIGTERM) or a clean idle exit is not an error.
    func testRequestedOrCleanIdleExitIsNotAnError() async {
        let closed = FakeChatSessionProcess(arguments: [])
        let first = makeClient { closed }
        await first.close(grace: .milliseconds(20))
        XCTAssertNil(first.exitError)

        let idle = FakeChatSessionProcess(arguments: [])
        let second = makeClient { idle }
        idle.exit(status: 0)
        await untilTurn { !second.isAlive }
        XCTAssertNil(second.exitError)
    }

    func testExitMessageIsBounded() {
        XCTAssertEqual(ChatSessionClient.exitMessage(status: 1, stderrTail: " \n"),
                       "The chat session ended unexpectedly (exit status 1).")
        let long = String(repeating: "x", count: 2000)
        XCTAssertLessThan(ChatSessionClient.exitMessage(status: 1, stderrTail: long).count, 600)
    }

    /// A pending session holds the turn until the pool launches it.
    func testPendingSessionHoldsTheTurnUntilLaunch() async {
        let fake = persistingFake()
        let client = makeClient(launchImmediately: false) { fake }
        XCTAssertTrue(client.isPending)
        XCTAssertTrue(client.isAlive)
        let starting = Task { await client.startTurn(self.command("held")) }
        await untilTurn { client.isBusy }
        XCTAssertTrue(fake.sent.isEmpty)
        client.launch()
        XCTAssertFalse(client.isPending)
        guard case .started = await starting.value else { return XCTFail("not started") }
        XCTAssertEqual(fake.turns.map(\.text), ["held"])
    }

    /// Stop without a `turn_done` (a hung provider): the watchdog ends the
    /// turn and kills the process.
    func testCancelWatchdogFinishesTheTurnWhenNoTurnDoneArrives() async throws {
        let fake = persistingFake()
        let client = makeClient { fake }
        _ = await client.startTurn(command())
        fake.emit(.textDelta(turnID: "t1", text: "stuck"))
        await untilTurn { client.liveTurn?.fullText == "stuck" }
        client.cancel(grace: .milliseconds(20))
        XCTAssertEqual(fake.sent.last, .cancel)
        await untilTurn { !client.isBusy && fake.terminated }
        XCTAssertEqual(try assistant()?.text, "stuck")
        XCTAssertFalse(client.isAlive, "a watchdog-killed session is never reused")
    }

    /// A `turn_done` inside the grace disarms the watchdog: nothing is killed.
    func testCancelAnsweredInTimeKeepsTheSessionAlive() async throws {
        let fake = persistingFake()
        let client = makeClient { fake }
        _ = await client.startTurn(command())
        client.cancel(grace: .milliseconds(30))
        fake.emit(.turnDone(turnID: "t1", status: .interrupted, sessionID: nil))
        await untilTurn { !client.isBusy }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(fake.terminated)
        XCTAssertTrue(client.isAlive)
        XCTAssertEqual(try assistant()?.status, "partial")
    }

    func testCloseSendsCloseThenTerminatesAfterGrace() async {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        await client.close(grace: .milliseconds(20))
        XCTAssertEqual(fake.sent, [.close])
        XCTAssertTrue(fake.terminated)
        XCTAssertFalse(fake.killed)
        XCTAssertFalse(client.isAlive)
    }

    func testCloseDoesNotTerminateAProcessThatExitsOnItsOwn() async {
        let fake = FakeChatSessionProcess(arguments: [])
        fake.exitsOnClose = true
        let client = makeClient { fake }
        await client.close(grace: .seconds(2))
        XCTAssertFalse(fake.terminated)
        XCTAssertFalse(fake.killed)
    }

    /// Quit sequence: `close`, wait, exactly ONE SIGTERM (a second one makes
    /// Go skip its temp-file cleanup), SIGKILL only when that is ignored.
    func testCloseEscalatesToKillOnlyWhenSIGTERMIsIgnored() async {
        let fake = FakeChatSessionProcess(arguments: [])
        fake.exitsOnTerminate = false
        let client = makeClient { fake }
        await client.close(grace: .milliseconds(20), killAfter: .milliseconds(20))
        XCTAssertEqual(fake.sent, [.close])
        XCTAssertEqual(fake.terminateCount, 1)
        XCTAssertTrue(fake.killed)
    }

    /// The stop watchdog and a later close on the same stubborn process
    /// still send SIGTERM only once.
    func testWatchdogThenCloseSendsSIGTERMOnce() async throws {
        let fake = persistingFake()
        fake.exitsOnTerminate = false
        let client = makeClient { fake }
        _ = await client.startTurn(command())
        client.cancel(grace: .milliseconds(10))
        await untilTurn { fake.terminated }
        await client.close(grace: .milliseconds(10), killAfter: .milliseconds(10))
        XCTAssertEqual(fake.terminateCount, 1)
        XCTAssertTrue(fake.killed)
    }

    func testAutomaticArgumentsDoNotAccidentallyCreateAPin() {
        let automatic = ChatSessionConfig(conversationID: 42, provider: "claude", model: "resolved-model", automatic: true)
        let args = ChatSessionClient.arguments(for: automatic, dbPath: nil, leaseOwnerID: "l")
        XCTAssertFalse(args.contains("--provider"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--routing-mode"))
        var observed = automatic
        observed.provider = "codex"
        observed.model = "actual-model"
        XCTAssertTrue(automatic.isCompatible(with: observed), "actual metadata must never retire a busy automatic host")
        observed.automatic = false
        XCTAssertFalse(automatic.isCompatible(with: observed))
        XCTAssertTrue(ChatSessionClient.arguments(for: observed, dbPath: nil, leaseOwnerID: "l").contains("--provider"))
        XCTAssertTrue(ChatSessionClient.arguments(for: observed, dbPath: nil, leaseOwnerID: "l").contains("--model"))
    }
}

/// A sleep the test opens by hand (the started timeout's manual clock).
final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private let signal = StateSignal()

    func wait() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
            signal.changed()
        }
        try Task.checkCancellation()
    }

    func untilWaiting() async {
        await signal.until { [self] in lock.withLock { !waiters.isEmpty } }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}
