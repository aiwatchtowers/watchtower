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
        ProviderCatalogFixture.seedShared() // retiring follows the claude_ai_tools row
        (dbPool, path) = try TestDatabase.createPool()
        // The conversations 1…6 the sessions write into (`--persist`).
        try dbPool.write { d in for _ in 1...6 { try TestDatabase.insertChatConversation(d) } }
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

    private func turn(_ id: String) -> ChatTurnCommand {
        ChatTurnCommand(turnID: id, text: "q", attachments: [], replay: false,
                        start: ChatTurnStart(mode: .send, titleText: "q"))
    }

    /// Board #592: while the login environment resolves, a requested session
    /// stays pending (no process is built without it) and launches once the
    /// wait returns.
    func testHeldAdmissionLaunchesOnlyAfterTheWait() async {
        let gate = AsyncGate()
        pool.holdAdmissionUntil { await gate.wait() }
        let client = pool.session(for: 1, config: config(1))
        await Task.yield()
        XCTAssertTrue(client.isPending, "no spawn while the environment resolves")
        XCTAssertTrue(fakes.isEmpty)
        gate.release()
        let launched = await waitForCondition { self.fakes.count == 1 }
        XCTAssertTrue(launched)
        XCTAssertFalse(client.isPending)
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
            client.send(turn("t\(id)"))
            busy.append(client)
            clock.advance(1)
        }
        let fourth = pool.session(for: 4, config: config(4))
        XCTAssertTrue(fourth.isPending)
        XCTAssertTrue(fourth.isAlive, "a queued session is usable: its turn waits")
        fourth.send(turn("t4"))
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
        await untilTurn { !self.fakes[3].turns.isEmpty }
        XCTAssertEqual(fakes[3].turns.map(\.turnID), ["t4"], "the held turn goes out at launch")
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// Stopping the held turn of a queued session ends that session: a freed
    /// slot launches nothing for it, and the next request gets a new one.
    func testStoppingAHeldTurnNeverLaunchesTheQueuedSession() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id)).send(turn("t\(id)"))
            clock.advance(1)
        }
        let fourth = pool.session(for: 4, config: config(4))
        fourth.send(turn("t4"))
        fourth.abandon()
        XCTAssertFalse(fourth.isBusy)
        XCTAssertFalse(fourth.isAlive)
        let rows = try await dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = 4") }
        XCTAssertEqual(rows, 0, "a held turn never reached its session: nothing was written, the draft comes back")

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: nil))
        pool.tick()
        XCTAssertFalse(fourth.isPending, "admission dropped it rather than launching it")
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
        busy.send(turn("t2"))

        pool.retireSessions(projectID: 7, deleted: false)
        XCTAssertNil(pool.client(for: 1))
        XCTAssertFalse(idle.isAlive)
        XCTAssertTrue(busy.isBusy, "a running turn is never cut")
        XCTAssertTrue(busy.isAlive)
        XCTAssertTrue(other.isAlive)

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: "sess-late"))
        let ended = await waitForCondition { !busy.isBusy }
        XCTAssertTrue(ended)
        // The stale session's id: Go records it only while the chat is still in
        // the project it was spawned for (`Turn.recordSession`), and it is never read (#604 G11).
        XCTAssertFalse(busy.isAlive, "the stale session is replaced on the next request")
        pool.tick()
        let reaped = await waitForCondition { self.fakes[1].terminated }
        XCTAssertTrue(reaped, "the policy tick closes the stale process")
        XCTAssertFalse(pool.session(for: 2, config: projectConfig(2, 7)) === busy)
        XCTAssertTrue(other.isAlive)
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// The claude.ai switches changed (#737): idle sessions close now, a busy
    /// one finishes its turn first (CHAT-03) — its session id still recorded,
    /// the prompt did not change — and is then replaced.
    func testChatPoolRetireIdleKeepsBusySessions() async throws {
        let idle = pool.session(for: 1, config: config(1))
        let busy = pool.session(for: 2, config: config(2))
        busy.send(turn("t2"))

        pool.retireIdleSessions()
        XCTAssertNil(pool.client(for: 1))
        XCTAssertFalse(idle.isAlive)
        let closed = await waitForCondition { self.fakes[0].terminated }
        XCTAssertTrue(closed, "the idle process is closed now")
        XCTAssertTrue(busy.isBusy, "a running turn is never cut")
        XCTAssertTrue(busy.isAlive)
        XCTAssertFalse(fakes[1].terminated)

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: "sess-2"))
        let ended = await waitForCondition { !busy.isBusy }
        XCTAssertTrue(ended)
        XCTAssertEqual(busy.driver.sessionID, "sess-2", "the next session resumes it")
        XCTAssertFalse(busy.isAlive, "replaced on the next request")
        XCTAssertFalse(pool.session(for: 2, config: config(2)) === busy)
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// Only Claude sessions load claude.ai tools: a Codex one stays warm.
    func testChatPoolRetireIdleLeavesOtherProviders() async {
        let codex = pool.session(for: 1, config: config(1, provider: "codex"))
        let claude = pool.session(for: 2, config: config(2))
        pool.retireIdleSessions()
        XCTAssertTrue(pool.client(for: 1) === codex)
        XCTAssertTrue(codex.isAlive)
        XCTAssertNil(pool.client(for: 2))
        XCTAssertFalse(claude.isAlive)
    }

    /// A queued session has not started: it reads the new switches when it
    /// launches, so it is left alone and keeps its held turn.
    func testChatPoolRetireIdleLeavesPendingSessions() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id)).send(turn("t\(id)"))
        }
        let fourth = pool.session(for: 4, config: config(4))
        fourth.send(turn("t4"))
        XCTAssertTrue(fourth.isPending)

        pool.retireIdleSessions()
        XCTAssertTrue(fourth.isPending)
        XCTAssertTrue(fourth.isAlive)
        XCTAssertEqual(fakes.count, 3, "no busy session was cut to make room")

        fakes[1].emit(.turnDone(turnID: "t2", status: .complete, sessionID: nil))
        let launched = await waitForCondition { self.fakes.count == 4 && !fourth.isPending }
        XCTAssertTrue(launched)
        await untilTurn { !self.fakes[3].turns.isEmpty }
        XCTAssertEqual(fakes[3].turns.map(\.turnID), ["t4"])
        XCTAssertTrue(fourth.isAlive, "the launched session is not retired")
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// A queued session's argv already carries the old `--resume`: it never
    /// launches. Its held turn never reached a provider, so it is re-sent on
    /// a fresh session with the new prompt (owner decision 2026-10-01), not
    /// left "Stopped".
    func testRetireSessionsResendsAPendingSessionsHeldTurnFresh() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id)).send(turn("t\(id)"))
            clock.advance(1)
        }
        let stale = ChatSessionConfig(conversationID: 4, provider: "claude", model: nil, projectID: 7)
        let queued = pool.session(for: 4, config: stale)
        queued.send(turn("t4"))
        XCTAssertTrue(queued.isPending)

        pool.retireSessions(projectID: 7, deleted: false)
        let replacement = try XCTUnwrap(pool.client(for: 4))
        XCTAssertFalse(replacement === queued)
        XCTAssertFalse(queued.isAlive)
        XCTAssertTrue(replacement.isBusy, "the held turn is still running, on the replacement")
        XCTAssertEqual(replacement.config.projectID, 7)
        let rows = try await dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = 4") }
        XCTAssertEqual(rows, 0, "nothing is written until the turn runs")

        fakes[0].emit(.turnDone(turnID: "t1", status: .complete, sessionID: nil))
        let launched = await waitForCondition { self.fakes.count == 4 && !replacement.isPending }
        XCTAssertTrue(launched)
        let fake = fakes[3]
        XCTAssertNil(fake.argument(after: "--resume"), "never the old session")
        XCTAssertEqual(fake.argument(after: "--project-id"), "7")
        await untilTurn { !fake.turns.isEmpty }
        XCTAssertEqual(fake.turns.map(\.turnID), ["t4"])
        // Whether it replays is the fresh session's own continuity (Go's
        // `ChatContinuity`: a chat with history replays it).
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
    }

    /// A deleted project's queued turn is re-sent outside any project.
    func testRetireSessionsOfADeletedProjectResendsWithoutTheProject() async throws {
        let stale = ChatSessionConfig(conversationID: 4, provider: "claude", model: nil, projectID: 7)
        let launchedFirst = pool.session(for: 4, config: stale)
        var changed = stale
        changed.model = "other-model"
        // Pending behind its predecessor's retirement, holding its turn.
        let queued = pool.session(for: 4, config: changed)
        queued.send(turn("t4"))
        XCTAssertTrue(queued.isPending)
        XCTAssertFalse(launchedFirst.isAlive)

        pool.retireSessions(projectID: 7, deleted: true)
        let replacement = try XCTUnwrap(pool.client(for: 4))
        XCTAssertNil(replacement.config.projectID)
        let launched = await waitForCondition { self.fakes.count == 2 && !replacement.isPending }
        XCTAssertTrue(launched)
        XCTAssertNil(fakes[1].argument(after: "--project-id"))
        XCTAssertNil(fakes[1].argument(after: "--resume"))
        await untilTurn { !self.fakes[1].turns.isEmpty }
        XCTAssertEqual(fakes[1].turns.map(\.turnID), ["t4"])
    }

    /// Closing one stale queued session re-runs admission: a second one
    /// queued behind it (on the old prompt) must already be out of
    /// the queue, or it launches into the slot that just opened.
    func testRetireSessionsNeverLaunchesAStaleSessionQueuedBehindAnother() throws {
        let launched = ChatSessionConfig(conversationID: 4, provider: "claude", model: nil, projectID: 7)
        _ = pool.session(for: 4, config: launched)
        var changed = launched
        changed.model = "other-model"
        // Waits for the first process's retirement, which cannot finish while
        // this test never yields; everything behind it waits in the queue.
        let blocked = pool.session(for: 4, config: changed)
        blocked.send(turn("t4"))
        let behind = pool.session(for: 5, config: ChatSessionConfig(conversationID: 5, provider: "claude", model: nil, projectID: 7))
        behind.send(turn("t5"))
        XCTAssertTrue(blocked.isPending)
        XCTAssertTrue(behind.isPending)

        pool.retireSessions(projectID: 7, deleted: false)
        for (id, stale) in [(Int64(4), blocked), (5, behind)] {
            let replacement = try XCTUnwrap(pool.client(for: id))
            XCTAssertFalse(replacement === stale)
            XCTAssertTrue(replacement.isBusy, "conversation \(id)'s held turn was re-sent")
        }
        for fake in fakes.dropFirst() {
            XCTAssertNil(fake.argument(after: "--resume"), "no stale session is ever launched")
            XCTAssertTrue([["t4"], ["t5"]].contains(fake.turns.map(\.turnID)))
            XCTAssertEqual(fake.turns.first?.replay, true)
        }
    }

    /// Retiring a BUSY session (close or config change) finishes its turn,
    /// which re-runs admission synchronously: the queued fourth must still
    /// wait for the retired process to exit — never 4 live processes.
    /// BEHAVIOR CHAT-03 — see docs/inventory/chat.md
    func testChat03RetiringABusySessionNeverLetsTheQueuedFourthOverlap() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id)).send(turn("t\(id)"))
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
        let conv: Int64 = 1
        let old = pool.session(for: conv, config: config(conv))
        old.send(turn("t"))
        await untilTurn { old.liveTurn != nil }
        fakes[0].emit(.textDelta(turnID: "t", text: "half"))
        _ = await waitForCondition { old.liveTurn?.fullText == "half" }

        let replacement = pool.session(for: conv, config: config(conv, provider: "codex"))
        XCTAssertTrue(replacement.isPending)
        XCTAssertEqual(fakes.count, 1, "no overlap: the replacement waits for the old process")
        await untilTurn { !old.isBusy }
        fakes[0].emit(.sessionReady(sessionID: "old-session", provider: "claude", model: ""))

        let spawned = await waitForCondition { self.fakes.count == 2 }
        XCTAssertTrue(spawned)
        XCTAssertTrue(fakes[0].hasExited)
        XCTAssertEqual(maxAlive, 1)
        fakes[1].emit(.sessionReady(sessionID: "new-session", provider: "codex", model: ""))
        let ready = await waitForCondition { replacement.driver.sessionID == "new-session" }
        XCTAssertTrue(ready)
        let text = try await dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE turn_id = 't' AND role = 'assistant'")
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
        let conv: Int64 = 1
        let busy = pool.session(for: conv, config: config(conv))
        _ = pool.session(for: 2, config: config(2))
        busy.send(turn("t"))
        fakes[0].emit(.textDelta(turnID: "t", text: "Hel"))
        _ = await waitForCondition { busy.liveTurn?.fullText == "Hel" }

        await pool.closeAll()

        XCTAssertTrue(pool.clients.isEmpty)
        XCTAssertTrue(fakes.allSatisfy { $0.sent.contains(.close) && $0.terminated })
        let fetched = try await dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE turn_id = 't' AND role = 'assistant'")
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
        let client = pool.session(for: 1, config: config(1))
        client.send(turn("t"))
        fakes[0].emit(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        let forwarded = await waitForCondition { finished == [1] }
        XCTAssertTrue(forwarded)
    }

    /// A connector call is held only inside its session's running turn
    /// (#737): no session, an idle one, or a dead one runs no turn.
    func testRunningTurnIDOnlyWhileALiveSessionRunsATurn() async throws {
        XCTAssertNil(pool.runningTurnID(conversationID: 1), "no session")
        let client = pool.session(for: 1, config: config(1))
        XCTAssertNil(pool.runningTurnID(conversationID: 1), "an idle session runs no turn")
        client.send(turn("t1"))
        await untilTurn { client.liveTurn != nil }
        XCTAssertEqual(pool.runningTurnID(conversationID: 1), "t1")
        XCTAssertNil(pool.runningTurnID(conversationID: 2), "another conversation's session")
        fakes[0].emit(.turnDone(turnID: "t1", status: .complete, sessionID: nil))
        let ended = await waitForCondition { self.pool.runningTurnID(conversationID: 1) == nil }
        XCTAssertTrue(ended, "a finished turn holds nothing")
        // The next turn starts once the last one's terminal write landed
        // (board #670): startTurn ignores a busy client.
        let settled = await waitForCondition { !client.isBusy }
        XCTAssertTrue(settled)
        client.send(turn("t2"))
        await untilTurn { client.liveTurn != nil }
        XCTAssertEqual(pool.runningTurnID(conversationID: 1), "t2")
        let row = { (turnID: String) in
            AgentAction(row: ["id": 1, "tool": ConnectorCallProposal.tool, "conversation_id": 1, "turn_id": turnID])
        }
        XCTAssertFalse(pool.holdsSessionCall(row("t1")), "a later turn does not hold an earlier turn's call")
        XCTAssertTrue(pool.holdsSessionCall(row("t2")))
        fakes[0].exit(status: 1)
        let gone = await waitForCondition { self.pool.runningTurnID(conversationID: 1) == nil }
        XCTAssertTrue(gone, "a dead session holds nothing")
    }
}

extension ChatSessionPoolTests {
    func testRoutingRevisionRetiresBothProvidersAfterTurnAndPreservesFIFO() async throws {
        for id: Int64 in 1...3 {
            pool.session(for: id, config: config(id, provider: "codex"))
                .send(turn("t\(id)"))
        }
        let fourth = pool.session(for: 4, config: config(4, provider: "codex"))
        fourth.send(turn("t4"))
        let fifth = pool.session(for: 5, config: config(5))
        fifth.send(turn("t5"))
        pool.retireRoutingSessions()
        XCTAssertTrue(fourth.isPending)
        XCTAssertTrue(fifth.isPending)
        XCTAssertTrue(fakes.allSatisfy { !$0.terminated && !$0.hasExited })
        XCTAssertEqual(fakes.count, 3, "Apply starts no replacement while active turns run")
        fakes[0].emit(.turnDone(turnID: "t1", status: .complete, sessionID: nil))
        let admitted = await waitForCondition { self.fakes.count == 4 && !fourth.isPending }
        XCTAssertTrue(admitted)
        XCTAssertTrue(fifth.isPending, "pending FIFO order survives revision publication")
        XCTAssertLessThanOrEqual(maxAlive, ChatSessionPolicy.maxLive)
        XCTAssertEqual(fakes[0].turns.count, 1, "the started turn was never replayed")
    }
}

extension ChatSessionClient {
    /// Sends `command` without waiting for its `started` (the start's
    /// outcome is not what these tests look at).
    func send(_ command: ChatTurnCommand) {
        begin(PendingChatStart(command: command))
    }
}
