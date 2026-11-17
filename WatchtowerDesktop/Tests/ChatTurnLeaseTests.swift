import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Desktop side of `chat_turn_leases` (spec 2026-11-15 §4.4, §5, §7):
/// the claim in the owner row's transaction, the phone's turn holding the
/// open chat, its Stop through the lease, a conversation deleted under the
/// Mac's own turn, the release at finalize and at launch.
@MainActor
final class ChatTurnLeaseTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var pool: ChatSessionPool!
    private var extraPools: [ChatSessionPool] = []
    private var fakes: [FakeChatSessionProcess] = []
    private var turnCounter = 0
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    /// The lease clock, fixed per test at the wall time the sessions (and
    /// the fake tower) stamp their own leases with.
    private let now = Date()
    private var nowMS: Int64 { ChatLease.milliseconds(now) }

    override func setUpWithError() throws {
        ProviderCatalogFixture.seedShared()
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaultsSuite = "ChatTurnLeaseTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        fakes = []
        extraPools = []
        turnCounter = 0
        pool = sessionPool(dbManager.dbPool)
    }

    override func tearDown() async throws {
        await pool.closeAll()
        for extra in extraPools { await extra.closeAll() }
        TestDatabase.cleanup(path: dbPath)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    private func sessionPool(_ dbPool: DatabasePool, launch: String = "launch-now") -> ChatSessionPool {
        ChatSessionPool(
            dbPool: dbPool,
            processFactory: { [weak self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                self?.fakes.append(fake)
                return fake
            },
            closeGrace: .milliseconds(20),
            leaseOwnerID: launch
        )
    }

    private func makeViewModel(
        dbManager: DatabaseManager? = nil, pool: ChatSessionPool? = nil
    ) -> ChatViewModel {
        let clock = now
        let makeTurnID: () -> String = { [weak self] in
            guard let self else { return UUID().uuidString }
            self.turnCounter += 1
            return "turn-\(self.turnCounter)"
        }
        return ChatViewModel(dbManager: dbManager ?? self.dbManager, pool: pool ?? self.pool, provider: .claude,
                             defaults: defaults, makeTurnID: makeTurnID) { clock }
    }

    private func conversation() throws -> Int64 {
        try dbManager.dbPool.write { try TestDatabase.insertChatConversation($0) }
    }

    private func hubLease(_ conv: Int64, turn: String = "hub-turn", heartbeatMS: Int64? = nil) throws {
        let beat = heartbeatMS ?? nowMS
        let claimed = try dbManager.dbPool.write { db in
            try ChatLeaseQueries.claim(db, ChatLease(conversationID: conv, owner: .hub, ownerID: "hub-1", turnID: turn,
                                                     startedAtMS: beat, heartbeatAtMS: beat), nowMS: beat)
        }
        XCTAssertTrue(claimed)
    }

    private func lease(_ conv: Int64) throws -> ChatLease? {
        try dbManager.dbPool.read { try ChatLeaseQueries.fetch($0, conversationID: conv) }
    }

    private func count(_ sql: String, _ conv: Int64) throws -> Int {
        try dbManager.dbPool.read { try Int.fetchOne($0, sql: sql, arguments: [conv]) ?? 0 }
    }

    // MARK: - Claim

    /// Spec §7 "Phone and Mac send at the same moment": two writers on two
    /// pools of one file claim the same chat; the first commit wins and the
    /// loser writes nothing.
    func testConcurrentClaimOneWins() async throws {
        let conv = try conversation()
        var config = Configuration()
        config.busyMode = .timeout(5)
        let poolA = try DatabasePool(path: dbPath, configuration: config)
        let poolB = try DatabasePool(path: dbPath, configuration: config)
        let sessionsA = sessionPool(poolA, launch: "launch-a")
        let sessionsB = sessionPool(poolB, launch: "launch-b")
        extraPools = [sessionsA, sessionsB]
        let vmA = makeViewModel(dbManager: DatabaseManager(pool: poolA), pool: sessionsA)
        let vmB = makeViewModel(dbManager: DatabaseManager(pool: poolB), pool: sessionsB)
        vmA.select(conversationID: conv)
        vmB.select(conversationID: conv)

        async let sentA = vmA.send(text: "from A")
        async let sentB = vmB.send(text: "from B")
        let results = await [sentA, sentB]

        XCTAssertEqual(results.filter { $0 }.count, 1, "exactly one send goes out")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ? AND role = 'user'", conv), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ? AND role = 'assistant'", conv), 1)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_turn_leases WHERE conversation_id = ?", conv), 1)
        let winner = results[0] ? "launch-a" : "launch-b"
        XCTAssertEqual(try lease(conv)?.ownerID, winner)
        XCTAssertEqual(fakes.flatMap(\.turns).count, 1, "the loser sent nothing")
    }

    /// Spec §5: while the hub holds the chat the send is refused before any
    /// row is written; the composer shows the phone's line and keeps the text.
    func testSendRefusedWhileHubHoldsLeaseKeepsDraft() async throws {
        let conv = try conversation()
        try hubLease(conv)
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        vm.draft = "hello from the Mac"

        await vm.sendDraft()

        XCTAssertEqual(vm.draft, "hello from the Mac", "the draft stays")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?", conv), 0, "nothing written")
        XCTAssertTrue(fakes.flatMap(\.turns).isEmpty, "nothing sent")
        XCTAssertEqual(vm.foreignTurn.line, "Answering from your iPhone — you can watch here")
        XCTAssertTrue(vm.isBusy, "Send is off until the release")
        XCTAssertNil(vm.errorMessage, "the line says it, not an error")
        XCTAssertEqual(try lease(conv)?.owner, .hub, "the hub's lease is untouched")
    }

    /// The Mac's Stop on the phone's turn sets the lease's cancel only.
    func testStopOnAPhoneTurnRequestsCancel() async throws {
        let conv = try conversation()
        try hubLease(conv)
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        await vm.refreshForeignTurn()
        XCTAssertEqual(vm.foreignTurn.turnID, "hub-turn")

        vm.stop()
        await waitForCondition { (try? self.lease(conv))?.cancelRequestedAtMS != nil }
        XCTAssertEqual(try lease(conv)?.owner, .hub)

        // The hub released it: the line goes, Send comes back.
        _ = try await dbManager.dbPool.write { try ChatLeaseQueries.release($0, conversationID: conv, turnID: "hub-turn") }
        await vm.refreshForeignTurn()
        XCTAssertNil(vm.foreignTurn.line)
        XCTAssertFalse(vm.isBusy)
    }

    // MARK: - The Mac's own turn

    /// The Mac's session claims the turn's lease as this app launch
    /// (`--lease-owner desktop --lease-owner-id`), exactly as the Swift claim
    /// did. A Stop the phone sets, and a conversation deleted under the
    /// turn, are the session's to honour now (Go:
    /// `TestPersist_RemoteStopEndsTheTurnWithPartial`,
    /// `TestPersist_LostLeaseStopsWritingAndCancels`).
    func testTheSessionClaimsTheLeaseAsThisLaunch() async throws {
        let conv = try conversation()
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        let sent = await vm.send(text: "q")
        XCTAssertTrue(sent)
        let fake = try XCTUnwrap(fakes.last)
        XCTAssertEqual(fake.argument(after: "--lease-owner"), "desktop")
        XCTAssertEqual(fake.argument(after: "--lease-owner-id"), "launch-now")
        let held = try XCTUnwrap(try lease(conv))
        XCTAssertEqual(held.owner, .desktop)
        XCTAssertEqual(held.ownerID, "launch-now")
        XCTAssertEqual(held.turnID, "turn-1")
    }

    /// A session that dies after `started` leaves its lease: the Mac sends
    /// `chat.recover`, so the next send is not refused as answering elsewhere.
    func testADeadSessionsTurnIsRecoveredSoTheNextSendGoesOut() async throws {
        let conv = try conversation()
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        _ = await vm.send(text: "q")
        let fake = try XCTUnwrap(fakes.last)
        fake.emit(.textDelta(turnID: "turn-1", text: "half"))
        await waitForCondition { vm.liveTurn?.fullText == "half" }
        fake.exit(status: 9)
        await waitForCondition { (try? self.lease(conv)) == nil }
        let marked = try count("""
            SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ? AND error_code = 'session_lost' AND status = 'partial'
            """, conv)
        XCTAssertEqual(marked, 1)
        let again = await vm.send(text: "again")
        XCTAssertTrue(again)
    }

    /// Spec §7 "Conversation deleted during a Mac-run turn" (CHAT-01): the
    /// session finds its chat gone, cancels the turn, lets it go
    /// (`turn_saved`) and ends; the Mac shows no error, recovers nothing and
    /// never reuses that session, and no orphan rows, steps or lease remain.
    /// The session's half (one cancel, no writes) is Go's guard of the same
    /// name (`cmd/ai_session_conv_deleted_test.go`); the fake plays it here.
    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testDriverStopsWhenConversationDeleted() async throws {
        let conv = try conversation()
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        _ = await vm.send(text: "q")
        let client = try XCTUnwrap(pool.client(for: conv))
        let fake = try XCTUnwrap(fakes.last)
        var lost = 0
        client.onTurnLost = { _, _ in lost += 1 }
        fake.emit(.textDelta(turnID: "turn-1", text: "Hel"))
        await waitForCondition { vm.liveTurn?.fullText == "Hel" }

        // Deleted from the phone: the cascade takes the rows and the lease.
        try await dbManager.dbPool.write { try $0.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [conv]) }
        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        await waitForCondition { !client.isBusy }
        fake.exit(status: 0)
        await waitForCondition { !client.isAlive }
        XCTAssertFalse(client.isAlive, "the session is not reused")
        XCTAssertEqual(lost, 0, "a turn it let go is not recovered")
        XCTAssertNil(vm.errorMessage, "an ended session of a deleted chat is not an error")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?", conv), 0)
        let steps = try await dbManager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_turn_steps") }
        XCTAssertEqual(steps, 0, "no orphan step")
        XCTAssertNil(try lease(conv))
    }

    /// A Stop pressed while a send waits for `chat.recover` (fix round 2)
    /// wins: the turn goes out once the recovery is done and is stopped at
    /// its `started`, like a held turn's Stop — the message stays with a
    /// `partial` reply and nothing more is answered.
    func testAStopWhileTheSendWaitsForRecoveryStopsTheTurnAtItsStart() async throws {
        let conv = try conversation()
        let (writes, tower) = FakeChatTower.writes(dbManager.dbPool)
        let vm = ChatViewModel(dbManager: dbManager, pool: pool, writes: writes, provider: .claude,
                               defaults: defaults) { [weak self] in
            guard let self else { return UUID().uuidString }
            self.turnCounter += 1
            return "turn-\(self.turnCounter)"
        }
        vm.select(conversationID: conv)
        await vm.send(text: "q1")
        let first = try XCTUnwrap(fakes.last)
        first.emit(.textDelta(turnID: "turn-1", text: "half"))
        await waitForCondition { vm.liveTurn?.fullText == "half" }
        let hold = TowerHold(tower)
        first.exit(status: 9)
        await waitForCondition { !tower.calls(.chatRecover).isEmpty }

        let sending = Task { await vm.send(text: "q2") }
        await waitForCondition { vm.pendingOwnerText == "q2" }
        XCTAssertTrue(vm.canStop, "Stop is offered while the send waits")
        vm.stop()
        hold.release()
        let sent = await sending.value
        XCTAssertTrue(sent, "the message stays in the transcript")
        let second = try XCTUnwrap(fakes.last)
        XCTAssertFalse(second === first)
        await waitForCondition { second.sent.contains(.cancel) }
        XCTAssertEqual(second.sent.filter { $0 == .cancel }.count, 1, "stopped at its started")
        second.emit(.turnDone(turnID: "turn-2", status: .interrupted, sessionID: nil))
        await waitForCondition { !vm.isBusy }
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ? AND role = 'user'", conv), 2)
        let last = try await dbManager.dbPool.read {
            try String.fetchOne($0, sql: "SELECT status FROM chat_messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 1",
                                arguments: [conv])
        }
        XCTAssertEqual(last, "partial")
    }

    func testFinalizeReleasesLease() async throws {
        let conv = try conversation()
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        _ = await vm.send(text: "q")
        XCTAssertEqual(try lease(conv)?.turnID, "turn-1")
        let fake = try XCTUnwrap(fakes.last)
        fake.emit(.textDelta(turnID: "turn-1", text: "done"))
        fake.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        await waitForCondition { !vm.isBusy && vm.thread.last?.message.status == "complete" }
        XCTAssertNil(try lease(conv), "released in the finalize transaction")

        // The next turn claims again.
        let again = await vm.send(text: "again")
        XCTAssertTrue(again)
        XCTAssertEqual(try lease(conv)?.turnID, "turn-2")
    }

    /// Spec §5: at launch the leases an earlier launch left (a crash) go;
    /// this launch's and the hub's stay.
    func testLaunchReleasesOwnStaleLeases() async throws {
        let earlier = try conversation()
        let current = try conversation()
        let hub = try conversation()
        try await dbManager.dbPool.write { db in
            for (conv, owner, id) in [(earlier, ChatLease.Owner.desktop, "launch-old"), (current, .desktop, "launch-now"),
                                      (hub, .hub, "hub-1")] {
                _ = try ChatLeaseQueries.claim(db, ChatLease(conversationID: conv, owner: owner, ownerID: id, turnID: "t",
                                                             startedAtMS: 1, heartbeatAtMS: 1), nowMS: 1)
            }
        }
        await AppState.releaseEarlierLaunchesChatLeases(.fake(dbManager.dbPool), launchID: "launch-now")
        XCTAssertNil(try lease(earlier))
        XCTAssertEqual(try lease(current)?.ownerID, "launch-now")
        XCTAssertEqual(try lease(hub)?.owner, .hub)
    }

    // MARK: - Chats panel

    func testPanelRowAnsweringForHubLease() throws {
        let phone = try conversation()
        let mac = try conversation()
        let stale = try conversation()
        try hubLease(phone)
        try hubLease(stale, turn: "old", heartbeatMS: nowMS - 60_001)
        try dbManager.dbPool.write { db in
            _ = try ChatLeaseQueries.claim(db, ChatLease(conversationID: mac, owner: .desktop, ownerID: "launch-now", turnID: "t",
                                                         startedAtMS: self.nowMS, heartbeatAtMS: self.nowMS), nowMS: self.nowMS)
        }
        let rows = try dbManager.dbPool.read { try ChatHistoryQueries.panelRows($0, projectID: nil, nowMS: self.nowMS) }
        func row(_ id: Int64) throws -> ChatPanelRow { try XCTUnwrap(rows.first { $0.id == id }) }

        XCTAssertTrue(try row(phone).answeringElsewhere)
        XCTAssertEqual(ChatPanelRowState(row: try row(phone), isAnswering: false), .answering)
        XCTAssertFalse(try row(mac).answeringElsewhere, "the Mac's own turn is the session pool's")
        XCTAssertFalse(try row(stale).answeringElsewhere, "a stale hub lease is a dead turn")
        XCTAssertEqual(ChatPanelRowState(row: try row(stale), isAnswering: false), .read)
    }
}
