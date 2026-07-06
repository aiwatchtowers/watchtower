import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

/// THE integration gate for the mobile feature (Plan 4 Task 10): the desktop
/// half (SlicePublisher + RelayProcessor over the real fixture DB) and the
/// mobile half (ReplicaHydrator + ActionOutbox + RelayFeed + ChatAssembler
/// over a ReplicaStore) — both built against the same frozen contracts by
/// different plans — wired over ONE shared InMemoryCloudTransport. Every
/// loop asserts BOTH sides' state: desktop DB rows AND the mobile overlay /
/// assembled chat thread, never just an absence of errors.
final class FullLoopTests: XCTestCase {
    // Desktop side.
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var publisher: SlicePublisher!
    // The one shared wire.
    private var transport: InMemoryCloudTransport!
    // Mobile side.
    private var store: ReplicaStore!
    private var outbox: ActionOutbox!
    private var assembler: ChatAssembler!
    private var feed: RelayFeed!
    private var hydrator: ReplicaHydrator!

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
        publisher = SlicePublisher(dbPool: dbPool, state: sidecar, transport: transport)
        store = try ReplicaStore.inMemory()
        outbox = ActionOutbox(transport: transport, store: store)
        assembler = ChatAssembler(transport: transport, store: store)
        feed = RelayFeed(transport: transport, store: store, outbox: outbox, assembler: assembler)
        hydrator = ReplicaHydrator(transport: transport, store: store)
    }

    override func tearDownWithError() throws {
        hydrator = nil
        feed = nil
        assembler = nil
        outbox = nil
        store = nil
        publisher = nil
        transport = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    /// The desktop's relay worker. Per-test because chat tests need their own
    /// scripted AI service; all instances share the sidecar, transport, and DB.
    private func makeProcessor(
        aiService: any AIServiceProtocol = MockClaudeService(),
        chunkInterval: Duration = .milliseconds(10)
    ) -> RelayProcessor {
        RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: aiService,
            chunkInterval: chunkInterval
        )
    }

    // MARK: - Action loop

    func testActionLoopResolvesInboxItemOnBothSides() async throws {
        // Desktop fixture row → SlicePublisher → DataZone → mobile replica.
        try await dbPool.write { db in try TestDatabase.insertInboxItem(db) } // id 1
        _ = try await publisher.publishOnce()
        _ = try await hydrator.hydrateOnce()
        let items = try store.fetchAll(InboxItem.self, kind: .inboxItem)
        XCTAssertEqual(items.map(\.id), [1], "the published fixture row must hydrate into the replica")
        XCTAssertEqual(items.first?.snippet, "Hey, can you review this?")
        XCTAssertEqual(items.first?.status, "pending")

        // Mobile enqueues the resolve against the replica record it just read.
        try await outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-1")

        // Own-echo discipline: a poll BEFORE the desktop acts sees only our
        // own still-pending record — skipped, overlay untouched, token advanced.
        let ownEcho = try await feed.pollOnce()
        XCTAssertEqual(ownEcho.echoes, 0, "mobile's own pending enqueue must not route as an echo")
        XCTAssertEqual(try XCTUnwrap(store.pendingActions().first).state, .pending)

        // Desktop applies the action to its DB and writes the applied echo.
        let applied = try await makeProcessor().processOnce()
        XCTAssertEqual(applied, 1)
        let (status, reason) = try await dbPool.read { db -> (String, String) in
            let row = try Row.fetchOne(
                db, sql: "SELECT status, resolved_reason FROM inbox_items WHERE id = 1"
            )
            return (row?["status"] ?? "", row?["resolved_reason"] ?? "")
        }
        XCTAssertEqual(status, "resolved")
        XCTAssertEqual(reason, "Resolved from mobile")

        // Mobile routes the applied echo: the optimistic overlay clears.
        let echoed = try await feed.pollOnce()
        XCTAssertEqual(echoed.echoes, 1)
        XCTAssertTrue(try store.pendingActions().isEmpty, "an applied echo must clear the pending overlay row")

        // And the authoritative slice change replaces the optimistic state.
        _ = try await publisher.publishOnce()
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(
            try store.fetchAll(InboxItem.self, kind: .inboxItem).first?.status,
            "resolved",
            "the resolved row must round-trip back into the replica"
        )
    }

    // MARK: - Failed loop

    func testFailedActionLoopCarriesDesktopErrorToOverlay() async throws {
        // No inbox_items row 999 anywhere — the desktop must refuse it.
        try await outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-999")

        let applied = try await makeProcessor().processOnce()
        XCTAssertEqual(applied, 0)

        let routed = try await feed.pollOnce()
        XCTAssertEqual(routed.echoes, 1)
        let row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.state, .failed)
        // The DESKTOP's message (RelayActionError.entityNotFound) must arrive
        // verbatim — not a mobile-side placeholder.
        XCTAssertEqual(row.errorMessage, "no row in inbox_items with id 999")

        let count = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items")
        }
        XCTAssertEqual(count, 0, "a failed action must leave the desktop DB untouched")
    }

    // MARK: - Chat loop

    func testChatLoopStreamsMultiChunkAnswerIntoMobileThread() async throws {
        // Events arrive 30 ms apart against a 10 ms flush interval, so each
        // text delta lands after the interval elapsed — the answer travels as
        // multiple wire chunks, not one blob (the streaming contract).
        let mock = MockClaudeService(
            events: [.text("Hello "), .text("streaming "), .text("world"), .done],
            eventDelay: .milliseconds(30)
        )
        let (sessionID, messageID) = try await assembler.send(text: "What changed today?", sessionID: nil)
        let awaiting = await assembler.firstChunkPending(messageID: messageID)
        XCTAssertTrue(awaiting, "before the desktop answers, the reply row must read as waiting")

        _ = try await makeProcessor(aiService: mock).processOnce()
        XCTAssertEqual(mock.prompts, ["What changed today?"], "the mobile turn's text must reach the AI service")

        let routed = try await feed.pollOnce()
        XCTAssertGreaterThanOrEqual(routed.chunks, 2, "the answer must travel as at least two chunks")

        let messages = try store.chatMessages(inSession: sessionID)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.first?.text, "What changed today?")
        let reply = try XCTUnwrap(messages.last)
        XCTAssertEqual(reply.id, messageID)
        XCTAssertEqual(reply.text, "Hello streaming world", "the assembled reply must be the full concatenation")
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)
        let stillAwaiting = await assembler.firstChunkPending(messageID: messageID)
        XCTAssertFalse(stillAwaiting)
        XCTAssertEqual(try store.chatSessions().first?.title, "What changed today?")
    }

    func testChatLoopErrorFlagArrivesEndToEnd() async throws {
        let failure = NSError(
            domain: "ai", code: 1, userInfo: [NSLocalizedDescriptionKey: "model exploded"]
        )
        let (sessionID, messageID) = try await assembler.send(text: "hello?", sessionID: nil)

        _ = try await makeProcessor(aiService: MockClaudeService(error: failure)).processOnce()
        _ = try await feed.pollOnce()

        let reply = try XCTUnwrap(store.chatMessages(inSession: sessionID).last)
        XCTAssertEqual(reply.id, messageID)
        XCTAssertTrue(reply.isError, "Task 1's is_error flag must survive the entire pipe")
        XCTAssertTrue(reply.isComplete, "an error final chunk still completes the message")
        XCTAssertEqual(reply.text, "⚠️ model exploded", "the desktop's error text must arrive verbatim")
    }

    // MARK: - Slice round-trip (DataZone loop)

    func testSliceRoundTripPushesAndDeletesTargetRow() async throws {
        let id = try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Ship the loop")
        }
        _ = try await publisher.publishOnce()
        _ = try await hydrator.hydrateOnce()
        let targets = try store.fetchAll(Target.self, kind: .target)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.text, "Ship the loop")
        XCTAssertEqual(targets.first?.status, "todo")

        // Deletion propagates too: publisher emits the delete, the hydrator
        // applies it, the replica row disappears.
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [id])
        }
        _ = try await publisher.publishOnce()
        _ = try await hydrator.hydrateOnce()
        XCTAssertTrue(try store.fetchAll(Target.self, kind: .target).isEmpty)
    }
}
