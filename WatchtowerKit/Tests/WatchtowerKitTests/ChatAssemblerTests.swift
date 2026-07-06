import GRDB
import os
import XCTest
@testable import WatchtowerKit

/// ChatAssembler contract (Plan 3 notes, frozen): per messageID ordered by
/// seq, text appends only for the next unseen seq, cut at the FIRST
/// `done: true` and ignore everything for that messageID afterward —
/// including stale higher-seq leftovers from a redelivered shorter answer.
/// Ingest is idempotent per chunk (RelayFeed replays whole batches after a
/// mid-batch throw), gaps are buffered in memory until they fill, and
/// `send` is transport-first: a transport throw persists nothing locally.
final class ChatAssemblerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Mutable test clock: `advance` moves every subsequent `now()` read.
    private final class Clock: @unchecked Sendable {
        private let state: OSAllocatedUnfairLock<Date>
        init(_ start: Date) { state = OSAllocatedUnfairLock(initialState: start) }
        func now() -> Date { state.withLock { $0 } }
        func advance(by seconds: TimeInterval) {
            state.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    private struct Fixtures {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let assembler: ChatAssembler
        let clock: Clock
    }

    private func makeFixtures() throws -> Fixtures {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let clock = Clock(base)
        let assembler = ChatAssembler(transport: transport, store: store) { clock.now() }
        return Fixtures(transport: transport, store: store, assembler: assembler, clock: clock)
    }

    private func chunk(
        messageID: String,
        seq: Int,
        text: String,
        done: Bool = false,
        isError: Bool? = nil // swiftlint:disable:this discouraged_optional_boolean
    ) -> ChatChunkPayload {
        ChatChunkPayload(sessionID: "S1", messageID: messageID, seq: seq, text: text, done: done, isError: isError)
    }

    private func assistantRow(_ store: ReplicaStore, sessionID: String) throws -> ChatMessage {
        try XCTUnwrap(store.chatMessages(inSession: sessionID).last { $0.role == .assistant })
    }

    // MARK: - send: session + user message + assistant placeholder

    func testSendCreatesSessionUserMessageAndPlaceholder() async throws {
        let f = try makeFixtures()

        let (sessionID, messageID) = try await f.assembler.send(
            text: "Summarize my inbox for today please and thanks",
            sessionID: nil
        )

        // Session row with title = first words of the opening message.
        let session = try XCTUnwrap(f.store.chatSessions().first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.title, "Summarize my inbox for today please…")
        XCTAssertEqual(session.createdAt, base)

        // User turn complete, assistant placeholder incomplete.
        let messages = try f.store.chatMessages(inSession: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "Summarize my inbox for today please and thanks")
        XCTAssertTrue(messages[0].isComplete)
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].id, messageID)
        XCTAssertEqual(messages[1].text, "")
        XCTAssertFalse(messages[1].isComplete)

        // The wire record landed in the relay zone as a chat_message whose id
        // is the messageID chunks will stream back under.
        let batch = try await f.transport.changes(in: .relay, since: nil)
        let record = try XCTUnwrap(batch.changed.first)
        XCTAssertEqual(record.kind, RelayRecordKind.chatMessage.rawValue)
        let payload = try RelayCoder.makeDecoder().decode(ChatMessagePayload.self, from: record.payload)
        XCTAssertEqual(payload.id, messageID)
        XCTAssertEqual(payload.sessionID, sessionID)
        XCTAssertEqual(payload.text, "Summarize my inbox for today please and thanks")
    }

    func testSendShortMessageTitleIsWholeText() async throws {
        let f = try makeFixtures()

        _ = try await f.assembler.send(text: "Plans for today?", sessionID: nil)

        XCTAssertEqual(try f.store.chatSessions().first?.title, "Plans for today?")
    }

    func testSendIntoExistingSessionKeepsTitleAndBumpsUpdatedAt() async throws {
        let f = try makeFixtures()
        let (sessionID, _) = try await f.assembler.send(text: "first question", sessionID: nil)
        f.clock.advance(by: 60)

        let (again, _) = try await f.assembler.send(text: "follow-up question", sessionID: sessionID)

        XCTAssertEqual(again, sessionID)
        let sessions = try f.store.chatSessions()
        XCTAssertEqual(sessions.count, 1)
        // Title stays the opening message's; activity bumps updated_at.
        XCTAssertEqual(sessions[0].title, "first question")
        XCTAssertEqual(sessions[0].updatedAt, base.addingTimeInterval(60))
        XCTAssertEqual(try f.store.chatMessages(inSession: sessionID).count, 4)
    }

    func testMessagesOrderUserTurnBeforeItsReplyAtSameTimestamp() async throws {
        // Both rows of one turn share createdAt (same send); the user turn
        // must still render before the reply it prompted.
        let f = try makeFixtures()
        let (sessionID, _) = try await f.assembler.send(text: "one", sessionID: nil)
        f.clock.advance(by: 1)
        _ = try await f.assembler.send(text: "two", sessionID: sessionID)

        let roles = try f.store.chatMessages(inSession: sessionID).map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .user, .assistant])
    }

    // MARK: - send: transport-first ordering (throw path)

    private struct ThrowingTransport: CloudSyncTransport {
        struct Failure: Error {}
        func save(_ records: [CloudRecord]) async throws { throw Failure() }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws { throw Failure() }
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            throw Failure()
        }
    }

    func testSendTransportThrowPersistsNothing() async throws {
        // Transport-first (mirrors ActionOutbox): a save throw must leave no
        // phantom thread awaiting an answer that can never come. The typed
        // text is not lost — send() throws, so the compose field keeps it.
        let store = try ReplicaStore.inMemory()
        let assembler = ChatAssembler(transport: ThrowingTransport(), store: store)

        do {
            _ = try await assembler.send(text: "will not go through", sessionID: nil)
            XCTFail("expected the transport throw to propagate")
        } catch is ThrowingTransport.Failure {
            // expected
        }

        XCTAssertTrue(try store.chatSessions().isEmpty)
        let orphans = try await store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages") ?? 0
        }
        XCTAssertEqual(orphans, 0)
    }

    // MARK: - ingest: ordered assembly

    func testOrderedAssemblyAppendsAndCompletes() async throws {
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "Hel"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 1, text: "lo"))
        var reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "Hello")
        XCTAssertFalse(reply.isComplete)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 2, text: " there", done: true))
        reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "Hello there")
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)
    }

    func testFirstChunkPendingLifecycle() async throws {
        let f = try makeFixtures()
        let (_, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        // Waiting for the first chunk right after send…
        var pending = await f.assembler.firstChunkPending(messageID: messageID)
        XCTAssertTrue(pending)
        // …not once any chunk has landed…
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "…"))
        pending = await f.assembler.firstChunkPending(messageID: messageID)
        XCTAssertFalse(pending)
        // …and never for a message this device does not know.
        pending = await f.assembler.firstChunkPending(messageID: "no-such-message")
        XCTAssertFalse(pending)

        // The Plan 3 notes' liveness threshold, exported for the Task 7 VM.
        XCTAssertEqual(ChatAssembler.unreachableAfter, .seconds(45))
    }

    // MARK: - ingest: cut at the FIRST done (the notes' redelivery scenario)

    func testCutAtFirstDoneIgnoresStaleHigherSeqLeftovers() async throws {
        // Crash-window redelivery re-streamed a SHORTER answer: the zone
        // holds rewritten chunks 0,1(done) plus orphaned done:false leftovers
        // 2,3 from the longer first stream. Ordered by seq, assembly must cut
        // at seq 1 and ignore the stale tail.
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "Short"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 1, text: " answer.", done: true))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 2, text: " stale"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 3, text: " leftovers"))

        let reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "Short answer.")
        XCTAssertTrue(reply.isComplete)
    }

    func testRedeliveredDoneAtAlreadyAppliedSeqCompletesWithoutAppending() async throws {
        // The other redelivery half: this device already applied 0..2 of the
        // crashed longer stream, then the rewritten seq-1 arrives done:true.
        // Its text was already applied under the old record version — mark
        // complete, append nothing.
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "A"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 1, text: "B"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 2, text: "C"))

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 1, text: "B", done: true))

        let reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "ABC")
        XCTAssertTrue(reply.isComplete)
    }

    // MARK: - ingest: idempotency (RelayFeed batch replays)

    func testDuplicateChunkIsNoOp() async throws {
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "once"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "once"))

        XCTAssertEqual(try assistantRow(f.store, sessionID: sessionID).text, "once")
    }

    func testFullBatchReplayLeavesThreadTextByteIdentical() async throws {
        // RelayFeed's contract: an ingest throw replays the WHOLE batch next
        // poll — so a full 0..done sequence delivered twice must assemble to
        // the exact same thread.
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)
        let batch = [
            chunk(messageID: messageID, seq: 0, text: "All "),
            chunk(messageID: messageID, seq: 1, text: "good "),
            chunk(messageID: messageID, seq: 2, text: "here.", done: true)
        ]

        for payload in batch { try await f.assembler.ingest(payload) }
        let firstPass = try assistantRow(f.store, sessionID: sessionID)
        for payload in batch { try await f.assembler.ingest(payload) }
        let secondPass = try assistantRow(f.store, sessionID: sessionID)

        XCTAssertEqual(firstPass.text, "All good here.")
        XCTAssertEqual(secondPass, firstPass)
    }

    // MARK: - ingest: gaps buffer until they fill

    func testShuffledIngestBuffersGapsAndAssemblesInSeqOrder() async throws {
        // The feed normally delivers chunks in seq order (the desktop saves
        // them that way and the buffer is seq-ordered) — but the assembler
        // BUFFERS out-of-order arrivals rather than dropping them, so a
        // shuffled delivery still assembles the exact text.
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 2, text: "2"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "0"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 3, text: "3", done: true))
        var reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "0")
        XCTAssertFalse(reply.isComplete)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 1, text: "1"))
        reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "0123")
        XCTAssertTrue(reply.isComplete)
    }

    func testBufferedStaleChunksDiscardedWhenDoneDrainsFirst() async throws {
        // Shuffled variant of the redelivery cut: the buffered drain reaches
        // done:true at seq 1 before the buffered 2 and 3 — they must be
        // discarded, not appended after completion.
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 3, text: "3"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 2, text: "2"))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 1, text: "1", done: true))
        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "0"))

        let reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertEqual(reply.text, "01")
        XCTAssertTrue(reply.isComplete)
    }

    // MARK: - ingest: isError propagation

    func testErrorFlagOnDoneChunkMarksReplyError() async throws {
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(
            chunk(messageID: messageID, seq: 0, text: "⚠️ chat stream timed out", done: true, isError: true)
        )

        let reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertTrue(reply.isComplete)
        XCTAssertTrue(reply.isError)
    }

    func testNilErrorFlagReadsAsNotError() async throws {
        // Pre-flag desktop versions omit is_error entirely → nil → false.
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "fine", done: true, isError: nil))

        let reply = try assistantRow(f.store, sessionID: sessionID)
        XCTAssertTrue(reply.isComplete)
        XCTAssertFalse(reply.isError)
    }

    // MARK: - ingest: unknown messageID

    func testChunkForUnknownMessageIsIgnored() async throws {
        // No local row means the thread never existed here (fresh install) or
        // send()'s local persist failed — resurrecting a lone assistant
        // bubble in an empty thread helps nobody. Logged, dropped, no throw.
        let f = try makeFixtures()

        try await f.assembler.ingest(chunk(messageID: "never-sent", seq: 0, text: "orphan", done: true))

        XCTAssertTrue(try f.store.chatSessions().isEmpty)
        let rows = try await f.store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages") ?? 0
        }
        XCTAssertEqual(rows, 0)
    }

    // MARK: - ValueObservation over the chat tables

    func testObservationFiresOnChunkApply() async throws {
        let f = try makeFixtures()
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)
        let observed = expectation(description: "observation sees the assembled reply")
        let store = f.store
        let observation = ValueObservation.tracking { db in
            try store.chatMessages(inSession: sessionID, from: db)
        }
        let cancellable = observation.start(
            in: f.store.reader,
            onError: { XCTFail("observation error: \($0)") },
            onChange: { messages in
                if messages.last?.text == "streamed", messages.last?.isComplete == true {
                    observed.fulfill()
                }
            }
        )
        defer { cancellable.cancel() }

        try await f.assembler.ingest(chunk(messageID: messageID, seq: 0, text: "streamed", done: true))
        await fulfillment(of: [observed], timeout: 5)
    }

    // MARK: - End-to-end through RelayFeed (redelivery replay)

    func testFeedRedeliveryKeepsThreadTextByteIdentical() async throws {
        // The self-review scenario: the same 0..done chunk records delivered
        // through RelayFeed twice (rewritten records → a second batch). The
        // assembled thread must not change byte-for-byte.
        let f = try makeFixtures()
        let outbox = ActionOutbox(transport: f.transport, store: f.store)
        let feed = RelayFeed(transport: f.transport, store: f.store, outbox: outbox, assembler: f.assembler)
        let (sessionID, messageID) = try await f.assembler.send(text: "hi", sessionID: nil)
        let records = try [
            chunk(messageID: messageID, seq: 0, text: "Stable "),
            chunk(messageID: messageID, seq: 1, text: "answer", done: true)
        ].map { try CloudRecordFactory.record(for: $0, modifiedAt: base) }

        try await f.transport.save(records)
        _ = try await feed.pollOnce()
        let firstPass = try assistantRow(f.store, sessionID: sessionID)
        try await f.transport.save(records) // rewrite → redelivered next poll
        _ = try await feed.pollOnce()
        let secondPass = try assistantRow(f.store, sessionID: sessionID)

        XCTAssertEqual(firstPass.text, "Stable answer")
        XCTAssertTrue(firstPass.isComplete)
        XCTAssertEqual(secondPass, firstPass)
    }
}
