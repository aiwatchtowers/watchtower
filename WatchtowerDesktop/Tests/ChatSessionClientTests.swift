import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatSessionClientTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var path: String!
    private var conversationID: Int64 = 0
    private var assistantID: Int64 = 0

    override func setUpWithError() throws {
        (dbPool, path) = try TestDatabase.createPool()
        (conversationID, assistantID) = try dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t1",
                                                           provider: "claude", model: "")
            return (conv, asst.id)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func config() -> ChatSessionConfig {
        ChatSessionConfig(conversationID: conversationID, provider: "claude", model: nil)
    }

    private func makeClient(_ spawn: @escaping () throws -> any ChatSessionProcess) -> ChatSessionClient {
        ChatSessionClient(config: config(), spawn: spawn, store: ChatTurnStore(dbPool: dbPool), clock: Date.init)
    }

    private func request(_ text: String = "hi") -> ChatTurnRequest {
        ChatTurnRequest(command: ChatTurnCommand(turnID: "t1", text: text, attachments: [], replay: false),
                        assistantMessageID: assistantID)
    }

    private func row() throws -> ChatMessageRecord {
        let id = assistantID
        return try XCTUnwrap(dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id])
        })
    }

    func testArgumentsCarryOnlyFlags() {
        var cfg = ChatSessionConfig(conversationID: 7, provider: "claude", model: "model-b", resumeSessionID: "s1")
        XCTAssertEqual(ChatSessionClient.arguments(for: cfg, dbPath: "/tmp/w.db"),
                       ["ai", "session", "--conversation", "7", "--provider", "claude", "--surface", "main",
                        "--model", "model-b", "--resume", "s1", "--db-path", "/tmp/w.db"])
        cfg.model = nil
        cfg.resumeSessionID = ""
        XCTAssertEqual(ChatSessionClient.arguments(for: cfg, dbPath: nil),
                       ["ai", "session", "--conversation", "7", "--provider", "claude", "--surface", "main"])
    }

    /// CHAT-04 (Swift half): the session argv is built from the config
    /// alone — the turn text and attachment paths exist only in the stdin
    /// command.
    /// BEHAVIOR CHAT-04 — see docs/inventory/chat.md
    func testChat04SessionArgvNeverCarriesContent() throws {
        let cfg = ChatSessionConfig(conversationID: 7, provider: "claude", model: nil, resumeSessionID: "s1")
        let args = ChatSessionClient.arguments(for: cfg, dbPath: "/tmp/w.db").joined(separator: " ")
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
    func testChat04TurnContentTravelsOnlyOnStdin() {
        let args = ChatSessionClient.arguments(for: config(), dbPath: "/tmp/w.db")
        let fake = FakeChatSessionProcess(arguments: args)
        let client = makeClient { fake }
        client.startTurn(ChatTurnRequest(
            command: ChatTurnCommand(turnID: "t1", text: "SECRET-TEXT",
                                     attachments: [ChatCommandAttachment(path: "/tmp/SECRET.png", mime: "image/png",
                                                                         name: "SECRET.png")],
                                     replay: false),
            assistantMessageID: assistantID))
        XCTAssertFalse(fake.arguments.joined(separator: " ").contains("SECRET"))
        XCTAssertEqual(fake.turns.first?.text, "SECRET-TEXT")
        XCTAssertEqual(fake.turns.first?.attachments.map(\.path), ["/tmp/SECRET.png"])
    }

    func testSessionArgumentsCarryProjectIDOnlyWhenSet() {
        var config = ChatSessionConfig(conversationID: 7, provider: "claude", model: nil)
        XCTAssertFalse(ChatSessionClient.arguments(for: config, dbPath: "/tmp/w.db").contains("--project-id"))
        config.projectID = 42
        let args = ChatSessionClient.arguments(for: config, dbPath: "/tmp/w.db")
        let flag = args.firstIndex(of: "--project-id")
        XCTAssertEqual(flag.map { args[$0 + 1] }, "42")
    }

    func testConfigCompatibilityIgnoresOnlyTheResumeHint() {
        let base = ChatSessionConfig(conversationID: 1, provider: "claude", model: "m", resumeSessionID: "a")
        XCTAssertTrue(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: "m",
                                                                resumeSessionID: "b")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 2, provider: "claude", model: "m")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "codex", model: "m")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: nil)))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: "m",
                                                                 surface: "target")))
        XCTAssertFalse(base.isCompatible(with: ChatSessionConfig(conversationID: 1, provider: "claude", model: "m",
                                                                 projectID: 3)),
                       "moving a chat into a project needs a session with the project prompt")
    }

    func testTurnStreamsIntoTheDatabaseAndReportsCompletion() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        var finished: [Int64] = []
        client.onTurnFinished = { finished.append($0) }
        client.startTurn(request())
        XCTAssertEqual(fake.turns.map(\.text), ["hi"])
        XCTAssertTrue(client.isBusy)

        fake.emit(.textDelta(turnID: "t1", text: "Hello"))
        fake.emit(.turnDone(turnID: "t1", status: .complete, sessionID: "s1"))
        let done = await waitForCondition { !client.isBusy }
        XCTAssertTrue(done)
        XCTAssertEqual(try row().text, "Hello")
        XCTAssertEqual(try row().status, "complete")
        XCTAssertEqual(finished, [conversationID])
        XCTAssertEqual(client.continuousLeafID, assistantID, "the session has now seen this answer")
    }

    /// While a turn runs, a second start is refused (never two turns on one session).
    func testStartTurnWhileBusyIsIgnored() {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request("one"))
        client.startTurn(request("two"))
        XCTAssertEqual(fake.turns.map(\.text), ["one"])
    }

    /// A spawn failure never throws at the caller: the turn fails visibly.
    func testSpawnFailureFailsTheTurnWithProviderUnavailable() throws {
        struct Boom: Error {}
        let client = makeClient { throw Boom() }
        XCTAssertFalse(client.isAlive)
        XCTAssertEqual(client.startupError?.code, .providerUnavailable)
        client.startTurn(request())
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(try row().errorCode, "provider_unavailable")
        XCTAssertNil(client.continuousLeafID, "a failed turn forces a replay next time")
    }

    func testSendFailureFailsTheTurn() throws {
        struct PipeClosed: Error {}
        let fake = FakeChatSessionProcess(arguments: [])
        fake.sendError = PipeClosed()
        let client = makeClient { fake }
        client.startTurn(request())
        XCTAssertFalse(client.isBusy)
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(try row().errorCode, "provider_unavailable")
    }

    func testProcessDeathKeepsPartialTextAndMarksTheClientDead() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request())
        fake.emit(.textDelta(turnID: "t1", text: "half"))
        fake.exit(status: 9)
        let dead = await waitForCondition { !client.isAlive }
        XCTAssertTrue(dead)
        XCTAssertEqual(try row().text, "half")
        XCTAssertEqual(try row().status, "partial")
    }

    /// A crash without a terminal event keeps the text as `partial` (CHAT-01)
    /// AND surfaces the exit status + stderr tail, including on the next turn.
    func testUnexpectedExitSurfacesStatusAndStderr() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request())
        fake.emit(.textDelta(turnID: "t1", text: "half"))
        fake.exit(status: 2, stderr: "panic: boom\n\ngoroutine 1\n")
        let dead = await waitForCondition { !client.isAlive }
        XCTAssertTrue(dead)
        XCTAssertEqual(try row().status, "partial")
        XCTAssertEqual(client.exitError?.code, .sessionLost)
        XCTAssertEqual(client.exitError?.message,
                       "The chat session ended unexpectedly (exit status 2). panic: boom goroutine 1")
        XCTAssertEqual(client.driver.lastSessionError, client.exitError)
        client.startTurn(request())
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(client.driver.lastSessionError?.code, .sessionLost)
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
        _ = await waitForCondition { !second.isAlive }
        XCTAssertNil(second.exitError)
    }

    func testExitMessageIsBounded() {
        XCTAssertEqual(ChatSessionClient.exitMessage(status: 1, stderrTail: " \n"),
                       "The chat session ended unexpectedly (exit status 1).")
        let long = String(repeating: "x", count: 2000)
        XCTAssertLessThan(ChatSessionClient.exitMessage(status: 1, stderrTail: long).count, 600)
    }

    /// A pending session holds the turn until the pool launches it.
    func testPendingSessionHoldsTheTurnUntilLaunch() {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = ChatSessionClient(config: config(), spawn: { fake }, store: ChatTurnStore(dbPool: dbPool),
                                       clock: Date.init, launchImmediately: false)
        XCTAssertTrue(client.isPending)
        XCTAssertTrue(client.isAlive)
        client.startTurn(request("held"))
        XCTAssertTrue(client.isBusy)
        XCTAssertTrue(fake.sent.isEmpty)
        client.launch()
        XCTAssertFalse(client.isPending)
        XCTAssertEqual(fake.turns.map(\.text), ["held"])
    }

    /// Stop on a held turn: nothing was sent, the row is kept as partial.
    func testCancelWhilePendingDropsTheHeldTurn() throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = ChatSessionClient(config: config(), spawn: { fake }, store: ChatTurnStore(dbPool: dbPool),
                                       clock: Date.init, launchImmediately: false)
        client.startTurn(request())
        client.cancel()
        XCTAssertFalse(client.isBusy)
        client.launch()
        XCTAssertTrue(fake.turns.isEmpty)
        XCTAssertEqual(try row().status, "partial")
    }

    /// Stop without a `turn_done` (a hung provider): the watchdog keeps the
    /// partial text and kills the process.
    func testCancelWatchdogFinishesTheTurnWhenNoTurnDoneArrives() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request())
        fake.emit(.textDelta(turnID: "t1", text: "stuck"))
        _ = await waitForCondition { client.liveTurn?.fullText == "stuck" }
        client.cancel(grace: .milliseconds(20))
        XCTAssertEqual(fake.sent.last, .cancel)
        let finished = await waitForCondition { !client.isBusy && fake.terminated }
        XCTAssertTrue(finished)
        XCTAssertEqual(try row().status, "partial")
        XCTAssertEqual(try row().text, "stuck")
        XCTAssertFalse(client.isAlive, "a watchdog-killed session is never reused")
    }

    /// A `turn_done` inside the grace disarms the watchdog: nothing is killed.
    func testCancelAnsweredInTimeKeepsTheSessionAlive() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request())
        client.cancel(grace: .milliseconds(30))
        fake.emit(.turnDone(turnID: "t1", status: .interrupted, sessionID: nil))
        _ = await waitForCondition { !client.isBusy }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(fake.terminated)
        XCTAssertTrue(client.isAlive)
        XCTAssertEqual(try row().status, "partial")
    }

    func testAdoptInitialContinuityOnlyBeforeTheFirstTurn() {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.adoptInitialContinuity(41)
        XCTAssertEqual(client.continuousLeafID, 41)
        client.startTurn(request())
        client.adoptInitialContinuity(99)
        XCTAssertEqual(client.continuousLeafID, 41)
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
        let fake = FakeChatSessionProcess(arguments: [])
        fake.exitsOnTerminate = false
        let client = makeClient { fake }
        client.startTurn(request())
        client.cancel(grace: .milliseconds(10))
        _ = await waitForCondition { fake.terminated }
        await client.close(grace: .milliseconds(10), killAfter: .milliseconds(10))
        XCTAssertEqual(fake.terminateCount, 1)
        XCTAssertTrue(fake.killed)
    }
}
