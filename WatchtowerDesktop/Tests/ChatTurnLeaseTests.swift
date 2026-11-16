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
    /// The lease clock: 2026-11-15, fixed.
    private let now = Date(timeIntervalSince1970: 1_794_700_000)
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

    private func sessionPool(_ dbPool: DatabasePool) -> ChatSessionPool {
        ChatSessionPool(
            dbPool: dbPool,
            processFactory: { [weak self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                self?.fakes.append(fake)
                return fake
            },
            closeGrace: .milliseconds(20)
        )
    }

    private func makeViewModel(
        dbManager: DatabaseManager? = nil, pool: ChatSessionPool? = nil, launch: String = "launch-now"
    ) -> ChatViewModel {
        let clock = now
        let makeTurnID: () -> String = { [weak self] in
            guard let self else { return UUID().uuidString }
            self.turnCounter += 1
            return "turn-\(self.turnCounter)"
        }
        return ChatViewModel(dbManager: dbManager ?? self.dbManager, pool: pool ?? self.pool, provider: .claude,
                             defaults: defaults, makeTurnID: makeTurnID, leaseOwnerID: launch) { clock }
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
        let sessionsA = sessionPool(poolA)
        let sessionsB = sessionPool(poolB)
        extraPools = [sessionsA, sessionsB]
        let vmA = makeViewModel(dbManager: DatabaseManager(pool: poolA), pool: sessionsA, launch: "launch-a")
        let vmB = makeViewModel(dbManager: DatabaseManager(pool: poolB), pool: sessionsB, launch: "launch-b")
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
        XCTAssertEqual(try lease(conv)?.cancelRequestedAtMS, nowMS)
        XCTAssertEqual(try lease(conv)?.owner, .hub)

        // The hub released it: the line goes, Send comes back.
        _ = try await dbManager.dbPool.write { try ChatLeaseQueries.release($0, conversationID: conv, turnID: "hub-turn") }
        await vm.refreshForeignTurn()
        XCTAssertNil(vm.foreignTurn.line)
        XCTAssertFalse(vm.isBusy)
    }

    // MARK: - The Mac's own turn

    /// Spec §7 "Stop from the other device": the cancel the phone set runs
    /// the session's own Stop (`cancel` to the process).
    func testDriverHonoursRemoteCancel() async throws {
        let conv = try conversation()
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        let sent = await vm.send(text: "q")
        XCTAssertTrue(sent)
        let client = try XCTUnwrap(pool.client(for: conv))
        let fake = try XCTUnwrap(fakes.last)
        let held = try XCTUnwrap(try lease(conv))
        XCTAssertEqual(held.owner, .desktop)
        XCTAssertEqual(held.ownerID, "launch-now")
        XCTAssertEqual(held.turnID, "turn-1")

        await client.driver.pollLease()
        XCTAssertNotEqual(fake.sent.last, .cancel, "no cancel requested yet")

        let requested = try await dbManager.dbPool.write { db in
            try ChatLeaseQueries.requestCancel(db, conversationID: conv, turnID: "turn-1", nowMS: 1)
        }
        XCTAssertTrue(requested)
        await client.driver.pollLease()
        XCTAssertEqual(fake.sent.last, .cancel)
        let cancels = fake.sent.filter { $0 == .cancel }.count
        await client.driver.pollLease()
        XCTAssertEqual(fake.sent.filter { $0 == .cancel }.count, cancels, "honoured once")

        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        await waitForCondition { !vm.isBusy }
        XCTAssertNil(try lease(conv), "finalize released it")
    }

    /// Spec §7 "Conversation deleted during a Mac-run turn": the first write
    /// that changes no row stops the turn's writes and cancels it; no orphan
    /// rows are left.
    func testDriverStopsWhenConversationDeleted() async throws {
        let conv = try conversation()
        let vm = makeViewModel()
        vm.select(conversationID: conv)
        _ = await vm.send(text: "q")
        let client = try XCTUnwrap(pool.client(for: conv))
        let fake = try XCTUnwrap(fakes.last)
        var gone = 0
        let cancelOnGone = client.driver.onConversationGone
        client.driver.onConversationGone = {
            gone += 1
            cancelOnGone?()
        }

        // Deleted from the phone: the cascade takes the rows and the lease.
        try await dbManager.dbPool.write { try $0.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [conv]) }
        fake.emit(.textDelta(turnID: "turn-1", text: "Hel"))
        await waitForCondition { client.driver.conversationGone }
        await client.driver.writesSettled()
        XCTAssertEqual(gone, 1)
        XCTAssertEqual(fake.sent.last, .cancel, "the turn is cancelled")

        fake.emit(.toolStart(ChatToolStart(turnID: "turn-1", id: "a", name: "search_knowledge", argsJSON: "{}")))
        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        await waitForCondition { !client.isBusy }
        await client.driver.writesSettled()
        XCTAssertEqual(gone, 1, "once")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?", conv), 0)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM chat_turn_steps WHERE message_id IN "
                                 + "(SELECT id FROM chat_messages WHERE conversation_id = ?)", conv), 0)
        let steps = try await dbManager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_turn_steps") }
        XCTAssertEqual(steps, 0, "no orphan step")
        XCTAssertNil(try lease(conv))
        XCTAssertFalse(client.isAlive, "the session is not reused")
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
        await AppState.releaseEarlierLaunchesChatLeases(dbManager.dbPool, launchID: "launch-now")
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
