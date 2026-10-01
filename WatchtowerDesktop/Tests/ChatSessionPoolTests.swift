import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatSessionPoolTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var path: String!
    private var fakes: [FakeChatSessionProcess] = []
    /// The most processes ever alive at once, measured at each spawn.
    private var maxAlive = 0
    private var clock: ChatTestClock!
    private var pool: ChatSessionPool!

    override func setUpWithError() throws {
        (dbPool, path) = try TestDatabase.createPool()
        fakes = []
        maxAlive = 0
        let clock = ChatTestClock()
        self.clock = clock
        pool = ChatSessionPool(
            dbPool: dbPool,
            processFactory: { [weak self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                if let self {
                    self.fakes.append(fake)
                    self.maxAlive = max(self.maxAlive, self.fakes.filter { !$0.hasExited }.count)
                }
                return fake
            },
            clock: { clock.now },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: path)
    }

    private func config(_ id: Int64, provider: String = "claude") -> ChatSessionConfig {
        ChatSessionConfig(conversationID: id, provider: provider, model: nil)
    }

    private func assistantRow() throws -> Int64 {
        try dbPool.write { d in
            try ChatTreeQueries.insertAssistant(d, conversationID: TestDatabase.insertChatConversation(d),
                                                parentID: nil, turnID: "t", provider: "claude", model: "").id
        }
    }

    private func turn(_ id: String, row: Int64) -> ChatTurnRequest {
        ChatTurnRequest(command: ChatTurnCommand(turnID: id, text: "q", attachments: [], replay: false),
                        assistantMessageID: row)
    }

    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03PoolNeverRunsMoreThanThreeSessions() async {
        for id: Int64 in 1...4 {
            _ = pool.session(for: id, config: config(id))
            clock.advance(1)
        }
        XCTAssertEqual(pool.clients.count, 3)
        XCTAssertNil(pool.client(for: 1), "the least recently used session is evicted")
        let launched = await waitForCondition { self.fakes.count == 4 }
        XCTAssertTrue(launched)
        XCTAssertTrue(fakes[0].terminated)
        XCTAssertEqual(fakes[0].sent.first, .close, "eviction asks politely before SIGTERM")
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive, "the evicted process exits before the new spawn")
    }

    /// A running turn is never cut to make room: the fourth conversation
    /// waits (its turn held) until a turn finishes, then takes that slot.
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03BusySessionsAreNeverEvictedTheFourthWaits() async throws {
        var busy: [ChatSessionClient] = []
        for id: Int64 in 1...3 {
            let client = pool.session(for: id, config: config(id))
            client.startTurn(turn("t\(id)", row: try assistantRow()))
            busy.append(client)
            clock.advance(1)
        }
        let fourth = pool.session(for: 4, config: config(4))
        XCTAssertTrue(fourth.isPending)
        XCTAssertTrue(fourth.isAlive, "a queued session is usable: its turn waits")
        let fourthRow = try assistantRow()
        fourth.startTurn(turn("t4", row: fourthRow))
        XCTAssertEqual(fakes.count, 3)
        XCTAssertTrue(busy.allSatisfy(\.isBusy), "no running turn was cut")
        pool.tick()
        XCTAssertEqual(fakes.count, 3)

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: nil))
        let launched = await waitForCondition { self.fakes.count == 4 && !fourth.isPending }
        XCTAssertTrue(launched)
        XCTAssertTrue(fakes[1].terminated, "the session that went idle made room")
        XCTAssertFalse(fakes[0].terminated)
        XCTAssertFalse(fakes[2].terminated)
        XCTAssertEqual(fakes[3].turns.map(\.turnID), ["t4"], "the held turn goes out at launch")
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// Stopping the held turn of a queued session ends that session: a freed
    /// slot launches nothing for it, and the next request gets a new one.
    func testStoppingAHeldTurnNeverLaunchesTheQueuedSession() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id)).startTurn(turn("t\(id)", row: try assistantRow()))
            clock.advance(1)
        }
        let fourth = pool.session(for: 4, config: config(4))
        let row = try assistantRow()
        fourth.startTurn(turn("t4", row: row))
        fourth.cancel()
        XCTAssertFalse(fourth.isBusy)
        XCTAssertFalse(fourth.isAlive)
        let status = try await dbPool.read { try String.fetchOne($0, sql: "SELECT status FROM chat_messages WHERE id = ?", arguments: [row]) }
        XCTAssertEqual(status, "partial", "the stopped turn keeps its row (CHAT-01)")

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: nil))
        pool.tick()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fakes.count, 3, "no process for a session whose only turn was stopped")

        let again = pool.session(for: 4, config: config(4))
        XCTAssertTrue(again.isAlive)
        XCTAssertFalse(again === fourth)
    }

    /// A chat project's prompt changed: its idle sessions close at once, a
    /// busy one finishes its turn first and is then no longer reused.
    func testRetireSessionsOfAProjectClosesIdleAndRetiresBusyAfterItsTurn() async throws {
        func projectConfig(_ id: Int64, _ project: Int64?) -> ChatSessionConfig {
            ChatSessionConfig(conversationID: id, provider: "claude", model: nil, projectID: project)
        }
        let idle = pool.session(for: 1, config: projectConfig(1, 7))
        let busy = pool.session(for: 2, config: projectConfig(2, 7))
        let other = pool.session(for: 3, config: projectConfig(3, nil))
        busy.startTurn(turn("t2", row: try assistantRow()))

        pool.retireSessions(projectID: 7)
        XCTAssertNil(pool.client(for: 1))
        XCTAssertFalse(idle.isAlive)
        XCTAssertTrue(busy.isBusy, "a running turn is never cut")
        XCTAssertTrue(busy.isAlive)
        XCTAssertTrue(other.isAlive)

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: nil))
        let ended = await waitForCondition { !busy.isBusy }
        XCTAssertTrue(ended)
        XCTAssertFalse(busy.isAlive, "the stale session is replaced on the next request")
        XCTAssertFalse(pool.session(for: 2, config: projectConfig(2, 7)) === busy)
        XCTAssertTrue(other.isAlive)
    }

    /// Retiring a BUSY session (close or config change) finishes its turn,
    /// which re-runs admission synchronously: the queued fourth must still
    /// wait for the retired process to exit — never 4 live processes.
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03RetiringABusySessionNeverLetsTheQueuedFourthOverlap() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id)).startTurn(turn("t\(id)", row: try assistantRow()))
            clock.advance(1)
        }
        let fourth = pool.session(for: 4, config: config(4))
        XCTAssertTrue(fourth.isPending)

        pool.close(conversationID: 1)
        XCTAssertTrue(fourth.isPending, "the closed process has not exited yet")
        XCTAssertEqual(fakes.count, 3)
        let launched = await waitForCondition { self.fakes.count == 4 }
        XCTAssertTrue(launched)
        XCTAssertTrue(fakes[0].hasExited)

        // Same shape via a config change on a busy session (conversation 2).
        let fifth = pool.session(for: 5, config: config(5))
        XCTAssertTrue(fifth.isPending)
        _ = pool.session(for: 2, config: config(2, provider: "codex"))
        XCTAssertEqual(fakes.count, 4, "neither the queued fifth nor the replacement overlaps the old process")
        let settled = await waitForCondition { self.fakes.count == 6 }
        XCTAssertTrue(settled)
        XCTAssertTrue(fakes[1].hasExited)
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03IdleSessionIsClosedByTheNextTickAfterTTL() async {
        _ = pool.session(for: 1, config: config(1))
        clock.advance(ChatSessionPolicy.idleTTL - 1)
        pool.tick()
        XCTAssertNotNil(pool.client(for: 1))
        clock.advance(2)
        pool.tick()
        XCTAssertNil(pool.client(for: 1))
        let closed = await waitForCondition { self.fakes[0].terminated }
        XCTAssertTrue(closed)
    }

    func testSpawnArgumentsCarryTheDatabasePath() {
        _ = pool.session(for: 5, config: config(5))
        XCTAssertEqual(fakes[0].argument(after: "--conversation"), "5")
        XCTAssertEqual(fakes[0].argument(after: "--db-path"), dbPool.path)
    }

    func testReusesACompatibleLiveSessionAndRecyclesAnIncompatibleOne() async {
        let first = pool.session(for: 1, config: config(1))
        XCTAssertTrue(pool.session(for: 1, config: config(1)) === first)
        XCTAssertEqual(fakes.count, 1)

        let second = pool.session(for: 1, config: config(1, provider: "codex"))
        XCTAssertFalse(second === first)
        XCTAssertEqual(pool.lastConfig?.provider, "codex")
        let spawned = await waitForCondition { self.fakes.count == 2 }
        XCTAssertTrue(spawned)
        XCTAssertEqual(fakes[1].argument(after: "--provider"), "codex")
        XCTAssertTrue(fakes[0].terminated)
    }

    /// A config change on a busy session: the old process exits BEFORE its
    /// replacement spawns, so they never overlap and the old one's late
    /// `session_id` can never land after the new one's.
    func testConfigChangeReplacementWaitsForThePredecessorToExit() async throws {
        let (conv, row) = try await dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t",
                                                           provider: "claude", model: "")
            return (conv, asst.id)
        }
        let old = pool.session(for: conv, config: config(conv))
        old.startTurn(turn("t", row: row))
        fakes[0].emit(.textDelta(turnID: "t", text: "half"))
        _ = await waitForCondition { old.liveTurn?.fullText == "half" }

        let replacement = pool.session(for: conv, config: config(conv, provider: "codex"))
        XCTAssertTrue(replacement.isPending)
        XCTAssertEqual(fakes.count, 1, "no overlap: the replacement waits for the old process")
        XCTAssertFalse(old.isBusy, "the old turn was kept as partial")
        fakes[0].emit(.sessionReady(sessionID: "old-session", provider: "claude", model: ""))

        let spawned = await waitForCondition { self.fakes.count == 2 }
        XCTAssertTrue(spawned)
        XCTAssertTrue(fakes[0].hasExited)
        XCTAssertEqual(maxAlive, 1)
        fakes[1].emit(.sessionReady(sessionID: "new-session", provider: "codex", model: ""))
        _ = await waitForCondition { replacement.driver.sessionID == "new-session" }
        let stored = try await dbPool.read { d in try ChatConversationQueries.fetchByID(d, id: conv)?.sessionID }
        XCTAssertEqual(stored, "new-session")
        let text = try await dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [row])
        }
        XCTAssertEqual(text?.text, "half")
        XCTAssertEqual(text?.status, "partial")
    }

    func testDeadSessionIsRespawnedOnNextRequest() async {
        _ = pool.session(for: 1, config: config(1))
        fakes[0].exit(status: 1)
        let dead = await waitForCondition { self.pool.client(for: 1)?.isAlive == false }
        XCTAssertTrue(dead)
        let again = pool.session(for: 1, config: config(1))
        XCTAssertTrue(again.isAlive)
        XCTAssertEqual(fakes.count, 2)
    }

    func testCloseConversationRetiresItsSession() async {
        _ = pool.session(for: 1, config: config(1))
        pool.close(conversationID: 1)
        XCTAssertNil(pool.client(for: 1))
        let closed = await waitForCondition { self.fakes[0].terminated }
        XCTAssertTrue(closed)
        pool.close(conversationID: 42) // unknown id: a no-op
    }

    /// CHAT-03 on quit, and CHAT-01 with it: every session gets `close` then
    /// SIGTERM, and a turn still streaming keeps its text as `partial`.
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03CloseAllClosesEverySessionAndKeepsPartialText() async throws {
        let (conv, asst) = try await dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t",
                                                           provider: "claude", model: "")
            return (conv, asst.id)
        }
        let busy = pool.session(for: conv, config: config(conv))
        _ = pool.session(for: conv + 100, config: config(conv + 100))
        busy.startTurn(turn("t", row: asst))
        fakes[0].emit(.textDelta(turnID: "t", text: "Hel"))
        _ = await waitForCondition { busy.liveTurn?.fullText == "Hel" }

        await pool.closeAll()

        XCTAssertTrue(pool.clients.isEmpty)
        XCTAssertTrue(fakes.allSatisfy { $0.sent.contains(.close) && $0.terminated })
        let fetched = try await dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [asst])
        }
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.text, "Hel")
        XCTAssertEqual(row.status, "partial")
    }

    /// Quit while a retirement is still in flight: `closeAll` waits for it.
    func testCloseAllAwaitsInFlightRetirements() async {
        _ = pool.session(for: 1, config: config(1))
        pool.close(conversationID: 1)
        XCTAssertFalse(fakes[0].hasExited)
        await pool.closeAll()
        XCTAssertTrue(fakes[0].hasExited)
    }

    func testTurnFinishedIsForwarded() async throws {
        var finished: [Int64] = []
        pool.onTurnFinished = { finished.append($0) }
        let asst = try await dbPool.write { d in
            try ChatTreeQueries.insertAssistant(d, conversationID: TestDatabase.insertChatConversation(d),
                                                parentID: nil, turnID: "t", provider: "claude", model: "").id
        }
        let client = pool.session(for: 1, config: config(1))
        client.startTurn(turn("t", row: asst))
        fakes[0].emit(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        let forwarded = await waitForCondition { finished == [1] }
        XCTAssertTrue(forwarded)
    }
}
