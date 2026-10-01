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

    func testTextIsFlushedAtMostOncePerSecondThenCompleted() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "Hel"))
        XCTAssertEqual(try row().text, "Hel", "the first delta flushes (no flush yet)")
        driver.apply(.textDelta(turnID: "t", text: "lo"))
        XCTAssertEqual(try row().text, "Hel", "inside the flush interval")
        clock.advance(1.1)
        driver.apply(.textDelta(turnID: "t", text: "!"))
        XCTAssertEqual(try row().text, "Hello!")
        XCTAssertEqual(try row().status, "partial")

        var finished: LiveTurn?
        driver.onTurnFinished = { finished = $0 }
        driver.apply(.usage(ChatUsage(turnID: "t", tokensIn: 3, tokensOut: 4, model: "model-b")))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: "s9"))
        let done = try row()
        XCTAssertEqual(done.status, "complete")
        XCTAssertEqual(done.tokensOut, 4)
        XCTAssertEqual(done.model, "model-b")
        XCTAssertNil(driver.liveTurn)
        XCTAssertEqual(finished?.messageID, messageID)
        let conv = conversationID
        let session = try pool.read { d in try ChatConversationQueries.fetchByID(d, id: conv)?.sessionID }
        XCTAssertEqual(session, "s9")
        XCTAssertEqual(driver.sessionID, "s9")
    }

    /// CHAT-02: every tool call is persisted as it happens.
    /// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
    func testChat02ToolStepsArePersistedImmediately() throws {
        let driver = makeDriver()
        let msg = messageID
        driver.begin(messageID: msg, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "search_knowledge", argsJSON: "{}")))
        var steps = try pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
        XCTAssertEqual(steps.map(\.state), [.running])
        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "3 hits",
                                          sources: [ChatSource(kind: "slack", title: "x", url: nil, ref: "r")])))
        steps = try pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
        XCTAssertEqual(steps.map(\.state), [.succeeded])
        XCTAssertEqual(steps.first?.sources.map(\.ref), ["r"])
    }

    func testInterruptedAndExitedKeepPartialText() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "part"))
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        XCTAssertEqual(try row().status, "partial")
        XCTAssertEqual(try row().text, "part")

        driver.begin(messageID: messageID, turnID: "t2")
        driver.apply(.textDelta(turnID: "t2", text: "more"))
        driver.apply(.exited(status: 9, stderrTail: ""))
        XCTAssertEqual(try row().text, "more")
        XCTAssertEqual(try row().status, "partial")
    }

    func testErrorMarksTheRowWithItsCodeAndMessage() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.error(ChatSessionError(turnID: "t", code: .rateLimit, message: "slow", retryable: true)))
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(try row().errorCode, "rate_limit")
        XCTAssertEqual(try row().errorMessage, "slow", "the session's own text is kept for the card")
        XCTAssertNil(driver.liveTurn)
    }

    /// CHAT-05 storage side: a completed turn's `:::artifact` blocks are
    /// versioned once finalize runs (A33/A38 — the driver persists, not the VM).
    func testCompleteTurnPersistsArtifacts() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::"))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        let conv = conversationID
        let saved = try pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertEqual(saved?.content, "body")
        XCTAssertEqual(saved?.version, 1)
    }

    /// A partial (interrupted/exited) turn still versions whatever artifacts
    /// it streamed — an unterminated block is kept as complete content.
    func testPartialTurnPersistsArtifacts() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody"))
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        let conv = conversationID
        let saved = try pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertEqual(saved?.content, "body")
    }

    /// An errored turn produces no artifacts, even if the text streamed so far
    /// contained a well-formed block.
    func testErroredTurnDoesNotPersistArtifacts() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: ":::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nbody\n:::"))
        driver.apply(.error(ChatSessionError(turnID: "t", code: .internalError, message: "boom", retryable: false)))
        let conv = conversationID
        let saved = try pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") }
        XCTAssertNil(saved)
    }

    /// Review round 1 finding: the message-finalizing write and the artifact
    /// write must commit as ONE transaction — a failure on either side must
    /// roll back both, never leave a `complete` row with no matching
    /// `chat_artifacts` rows (or vice versa). Failure injected via a SQLite
    /// trigger on the artifact insert (the `testChat01NothingIsSentWhen…`
    /// precedent in `ChatViewModelTests.swift`).
    func testArtifactWriteFailureRollsBackTheMessageFinalize() throws {
        try pool.write { db in
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

        XCTAssertEqual(try row().status, "partial", "the message write rolled back with the failed artifact write")
        let conv = conversationID
        XCTAssertNil(try pool.read { try ChatArtifactQueries.latest($0, conversationID: conv, key: "q3") })
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
    func testFinishWithoutARunningTurnIsANoOp() throws {
        let driver = makeDriver()
        var calls = 0
        driver.onTurnFinished = { _ in calls += 1 }
        driver.finishRunningAsPartial()
        XCTAssertEqual(calls, 0)
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        driver.finishRunningAsPartial()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try row().status, "complete")
    }
}
