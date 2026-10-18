import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ChatTurnDriverTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var clock = ChatTestClock()
    private var conversationID: Int64 = 0
    private var messageID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        clock = ChatTestClock()
        (conversationID, messageID) = try pool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let msg = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: nil, turnID: "t", provider: "claude", model: "")
            return (conv, msg.id)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func makeDriver() -> ChatTurnDriver {
        let clock = self.clock
        return ChatTurnDriver(conversationID: conversationID, store: ChatTurnStore(dbPool: pool)) { clock.now }
    }

    private func row() throws -> ChatMessageRecord {
        let id = messageID
        return try XCTUnwrap(pool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id])
        })
    }

    func testTextIsFlushedAtMostOncePerSecondThenCompleted() async throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "Hel"))
        await driver.writesSettled()
        XCTAssertEqual(try row().text, "Hel", "the first delta flushes (no flush yet)")
        driver.apply(.textDelta(turnID: "t", text: "lo"))
        await driver.writesSettled()
        XCTAssertEqual(try row().text, "Hel", "inside the flush interval")
        clock.advance(1.1)
        driver.apply(.textDelta(turnID: "t", text: "!"))
        await driver.writesSettled()
        XCTAssertEqual(try row().text, "Hello!")
        XCTAssertEqual(try row().status, "partial")

        var finished: LiveTurn?
        driver.onTurnFinished = { finished = $0 }
        driver.apply(.usage(ChatUsage(turnID: "t", tokensIn: 3, tokensOut: 4, model: "model-b")))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: "s9"))
        await driver.writesSettled()
        let done = try row()
        XCTAssertEqual(done.status, "complete")
        XCTAssertEqual(done.tokensOut, 4)
        XCTAssertEqual(done.model, "model-b")
        XCTAssertNil(driver.liveTurn)
        XCTAssertEqual(finished?.messageID, messageID)
        let conv = conversationID
        let session = try await pool.read { d in try ChatConversationQueries.fetchByID(d, id: conv)?.sessionID }
        XCTAssertEqual(session, "s9")
        XCTAssertEqual(driver.sessionID, "s9")
    }

    /// CHAT-02: every tool call is persisted as it happens.
    /// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
    func testChat02ToolStepsArePersistedImmediately() async throws {
        let driver = makeDriver()
        let msg = messageID
        driver.begin(messageID: msg, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "search_knowledge", argsJSON: "{}")))
        await driver.writesSettled()
        var steps = try await pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
        XCTAssertEqual(steps.map(\.state), [.running])
        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "3 hits",
                                          sources: [ChatSource(kind: "slack", title: "x", url: nil, ref: "r")])))
        await driver.writesSettled()
        steps = try await pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
        XCTAssertEqual(steps.map(\.state), [.succeeded])
        XCTAssertEqual(steps.first?.sources.map(\.ref), ["r"])
    }

    func testInterruptedAndExitedKeepPartialText() async throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "part"))
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        await driver.writesSettled()
        XCTAssertEqual(try row().status, "partial")
        XCTAssertEqual(try row().text, "part")

        driver.begin(messageID: messageID, turnID: "t2")
        driver.apply(.textDelta(turnID: "t2", text: "more"))
        driver.apply(.exited(status: 9, stderrTail: ""))
        await driver.writesSettled()
        XCTAssertEqual(try row().text, "more")
        XCTAssertEqual(try row().status, "partial")
    }

    func testErrorMarksTheRowWithItsCodeAndMessage() async throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.error(ChatSessionError(turnID: "t", code: .rateLimit, message: "slow", retryable: true)))
        await driver.writesSettled()
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(try row().errorCode, "rate_limit")
        XCTAssertEqual(try row().errorMessage, "slow", "the session's own text is kept for the card")
        XCTAssertNil(driver.liveTurn)
    }

    /// CHAT-05 storage side: a completed turn's `:::artifact` blocks are
    /// versioned once finalize runs (A33/A38 — the driver persists, not the VM).
    func testCompleteTurnPersistsArtifacts() async throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::"))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        await driver.writesSettled()
        let conv = conversationID
        let saved = try await pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertEqual(saved?.content, "body")
        XCTAssertEqual(saved?.version, 1)
    }

    /// A partial (interrupted/exited) turn still versions whatever artifacts
    /// it streamed — an unterminated block is kept as complete content.
    func testPartialTurnPersistsArtifacts() async throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody"))
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        await driver.writesSettled()
        let conv = conversationID
        let saved = try await pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertEqual(saved?.content, "body")
    }

    /// An errored turn produces no artifacts, even if the text streamed so far
    /// contained a well-formed block.
    func testErroredTurnDoesNotPersistArtifacts() async throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::"))
        driver.apply(.error(ChatSessionError(turnID: "t", code: .internalError, message: "boom", retryable: false)))
        await driver.writesSettled()
        let conv = conversationID
        let saved = try await pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertNil(saved)
    }

    /// Review round 1 finding: the message-finalizing write and the artifact
    /// write must commit as ONE transaction — a failure on either side must
    /// roll back both, never leave a `complete` row with no matching
    /// `chat_artifacts` rows (or vice versa). Failure injected via a SQLite
    /// trigger on the artifact insert (the `testChat01NothingIsSentWhen…`
    /// precedent in `ChatViewModelTests.swift`).
    func testArtifactWriteFailureRollsBackTheMessageFinalize() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_artifact BEFORE INSERT ON chat_artifacts
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::"))
        var finished: LiveTurn?
        driver.onTurnFinished = { finished = $0 }
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))

        await driver.writesSettled()
        XCTAssertEqual(try row().status, "partial", "the message write rolled back with the failed artifact write")
        let conv = conversationID
        let artifact = try await pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertNil(artifact)
        XCTAssertNotNil(finished?.persistError)
        XCTAssertNil(driver.liveTurn, "the turn still ends — a stuck retry loop is worse than a lost write")
    }

    func testEventsForAnotherTurnAreIgnored() {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "stale", text: "zzz"))
        driver.apply(.turnDone(turnID: "stale", status: .complete, sessionID: nil))
        driver.apply(.error(ChatSessionError(turnID: "stale", code: .internalError, message: "x", retryable: false)))
        XCTAssertEqual(driver.liveTurn?.fullText, "")
        XCTAssertEqual(driver.liveTurn?.isRunning, true)
    }

    /// A session-level error with no running turn is remembered, not dropped.
    func testSessionErrorWithoutATurnIsKept() {
        let driver = makeDriver()
        driver.apply(.error(ChatSessionError(turnID: nil, code: .auth, message: "login", retryable: false)))
        XCTAssertEqual(driver.lastSessionError?.code, .auth)
    }

    /// Degenerate: finishing with no running turn is a no-op, and a finished
    /// turn is never re-finalized.
    func testFinishWithoutARunningTurnIsANoOp() async throws {
        let driver = makeDriver()
        var calls = 0
        driver.onTurnFinished = { _ in calls += 1 }
        driver.finishRunningAsPartial()
        await driver.writesSettled()
        XCTAssertEqual(calls, 0)
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        driver.finishRunningAsPartial()
        await driver.writesSettled()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try row().status, "complete")
    }

    private func steps() throws -> [ChatTurnStep] {
        let msg = messageID
        return try pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
    }

    private func wait(_ id: String, action: Int64, turn: String = "t") -> ChatEvent {
        .toolWait(ChatToolWait(turnID: turn, id: id, actionID: action, message: "Waiting for your approval"))
    }

    /// CHAT-02: a call the gate holds for the owner's approval is a visible
    /// waiting step until its `tool_end`; a denied/timed-out one is a red
    /// step carrying the gate's reason, an approved one a normal step.
    /// Waiting is live only — `chat_turn_steps` sees the usual start/end.
    /// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
    func testChat02WaitingStepIsVisibleUntilItEnds() throws {
        let driver = makeDriver()
        let turn = driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "mcp__claude_ai_Gmail__send", argsJSON: "{}")))
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "b", name: "mcp__claude_ai_Docs__create", argsJSON: "{}")))
        driver.apply(wait("a", action: 41))
        driver.apply(wait("b", action: 42))
        XCTAssertEqual(turn.steps.map(\.state), [.waiting(actionID: 41), .waiting(actionID: 42)])
        XCTAssertEqual(turn.steps.map(\.summary), ["Waiting for your approval", "Waiting for your approval"])
        XCTAssertEqual(turn.waitingActionIDs, [41, 42])
        XCTAssertEqual(try steps().map(\.state), [.running, .running], "waiting is never persisted")

        clock.advance(5)
        driver.apply(.textDelta(turnID: "t", text: "still thinking"))
        XCTAssertEqual(turn.steps.first?.state, .waiting(actionID: 41), "a waiting step stays until its tool_end")

        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: false, summary: "not approved within 15 minutes",
                                          sources: [])))
        XCTAssertEqual(turn.steps[0].state, .failed)
        XCTAssertEqual(turn.steps[0].summary, "not approved within 15 minutes")
        XCTAssertEqual(turn.waitingActionIDs, [42], "the other call keeps waiting on its own")
        XCTAssertEqual(try steps().first?.state, .failed)
        XCTAssertEqual(try steps().first?.summary, "not approved within 15 minutes")

        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "b", ok: true, summary: "created", sources: [])))
        XCTAssertEqual(turn.steps[1].state, .succeeded)
        XCTAssertEqual(turn.waitingActionIDs, [])
        XCTAssertEqual(try steps().map(\.state), [.failed, .succeeded])
    }

    /// A new wait (not a repeat, not a late one) asks the action feeds to
    /// re-read: the session subprocess wrote the row the step points at.
    func testOnlyANewWaitAnnouncesItsAction() {
        let driver = makeDriver()
        var announced: [Int64] = []
        driver.onActionAwaited = { announced.append($0) }
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "x", argsJSON: "{}")))
        driver.apply(wait("a", action: 9))
        driver.apply(wait("a", action: 9))
        driver.apply(wait("b", action: 9, turn: "stale"))
        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "", sources: [])))
        driver.apply(wait("a", action: 9))
        XCTAssertEqual(announced, [9])
    }

    /// Degenerate waits: another turn's, a wait for a finished step (late,
    /// never reopens it), a repeated wait, and one whose start never arrived
    /// (still a visible step). A turn that ends while a call waits leaves no
    /// step claiming it still waits.
    func testToolWaitDegenerateCases() throws {
        let driver = makeDriver()
        let turn = driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "x", argsJSON: "{}")))
        driver.apply(wait("a", action: 1, turn: "stale"))
        XCTAssertEqual(turn.steps.first?.state, .running)

        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "done", sources: [])))
        driver.apply(wait("a", action: 1))
        XCTAssertEqual(turn.steps.first?.state, .succeeded, "a late wait never reopens a finished step")
        XCTAssertEqual(turn.steps.first?.summary, "done")

        driver.apply(wait("orphan", action: 2))
        driver.apply(wait("orphan", action: 2))
        XCTAssertEqual(turn.steps.count, 2, "a wait without its start is one visible step")
        XCTAssertEqual(turn.steps.last?.state, .waiting(actionID: 2))
        XCTAssertEqual(try steps().map(\.toolID), ["a", "orphan"], "its start is persisted, never its waiting state")
        XCTAssertEqual(try steps().last?.state, .running)

        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "orphan", name: "late_name", argsJSON: #"{"k":1}"#)))
        XCTAssertEqual(turn.steps.last?.name, "late_name", "a start after its wait names the step")
        XCTAssertEqual(turn.steps.last?.state, .waiting(actionID: 2))
        XCTAssertEqual(try steps().last?.name, "late_name")

        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        XCTAssertEqual(turn.steps.last?.state, .running, "an ended turn's unfinished call reads as stopped")
        XCTAssertEqual(turn.waitingActionIDs, [])
        XCTAssertEqual(try steps().map(\.toolID), ["a", "orphan"], "the held call is still a step after the turn")
    }
}
