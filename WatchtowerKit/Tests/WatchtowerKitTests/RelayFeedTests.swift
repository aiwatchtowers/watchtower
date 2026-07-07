import GRDB
import os
import XCTest
@testable import WatchtowerKit

/// RelayFeed contract: the phone's SINGLE relay consumer (Plan 4 decision 3).
/// It owns the persisted relay token and fans records out in-process —
/// action echoes → ActionOutbox (own still-pending enqueues skipped), chat
/// chunks → the ChatChunkAssembling seam, heartbeats → ReplicaStore liveness.
/// Unknown kinds and undecodable payloads are logged and skipped; the token
/// always advances at batch end (never wedge) with the replica's monotonic
/// stale-batch drop.
final class RelayFeedTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private actor RecordingAssembler: ChatChunkAssembling {
        private(set) var chunks: [ChatChunkPayload] = []
        func ingest(_ chunk: ChatChunkPayload) async throws {
            chunks.append(chunk)
        }
    }

    private struct Fixtures {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let outbox: ActionOutbox
        let feed: RelayFeed
    }

    private func makeFixtures(
        assembler: (any ChatChunkAssembling)? = nil,
        onActionApplied: (@Sendable () async -> Void)? = nil
    ) throws -> Fixtures {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: transport, store: store)
        let feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            assembler: assembler,
            onActionApplied: onActionApplied
        )
        return Fixtures(transport: transport, store: store, outbox: outbox, feed: feed)
    }

    /// The desktop's rewrite of an action record carrying its verdict.
    private func echoRecord(
        _ action: ActionRequestPayload,
        status: ActionStatus,
        errorMessage: String? = nil
    ) throws -> CloudRecord {
        var echo = action
        echo.status = status
        echo.errorMessage = errorMessage
        return try CloudRecordFactory.record(for: echo, modifiedAt: base)
    }

    private func chunk(seq: Int = 0, done: Bool = false) -> ChatChunkPayload {
        ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: seq, text: "part \(seq)", done: done)
    }

    // MARK: - Action echo routing

    func testAppliedEchoRemovesPendingOverlayRow() async throws {
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.transport.save([try echoRecord(action, status: .applied)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 1)
        XCTAssertEqual(result.chunks, 0)
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
    }

    func testFailedEchoMarksOverlayRowFailed() async throws {
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-2")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.transport.save([try echoRecord(action, status: .failed, errorMessage: "inbox row 2 not found")])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 1)
        let row = try XCTUnwrap(f.store.pendingActions().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, "inbox row 2 not found")
    }

    func testOwnPendingEnqueueEchoIsSkipped() async throws {
        // Right after enqueue the feed sees our OWN record with status
        // pending — not a desktop verdict. It must not be routed, but the
        // token must still advance past it.
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .trackRead, entityRecordName: "track-3")

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 0)
        XCTAssertEqual(try XCTUnwrap(f.store.pendingActions().first).state, .pending)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    // MARK: - Chat chunk routing

    func testChatChunkRoutedToAssembler() async throws {
        let assembler = RecordingAssembler()
        let f = try makeFixtures(assembler: assembler)
        let payload = chunk(seq: 0)
        try await f.transport.save([try CloudRecordFactory.record(for: payload, modifiedAt: base)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.chunks, 1)
        XCTAssertEqual(result.echoes, 0)
        let received = await assembler.chunks
        XCTAssertEqual(received, [payload])
    }

    func testChatChunkDroppedWithoutAssemblerAndTokenAdvances() async throws {
        // Until Task 5 wires ChatAssembler, chunks are DROPPED — the token
        // advances, so they never replay. Acceptable only while no chat UI
        // exists; see the seam comment in RelayFeed.
        let f = try makeFixtures()
        try await f.transport.save([try CloudRecordFactory.record(for: chunk(), modifiedAt: base)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.chunks, 0)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    func testChatMessageEchoIgnoredSilently() async throws {
        // Our own outgoing user turns reflect back through the shared zone;
        // the desktop is their consumer. Known kind — no unknown-kind warning.
        let f = try makeFixtures()
        let message = ChatMessagePayload(id: "M1", sessionID: "S1", text: "hi", createdAt: base)
        try await f.transport.save([try CloudRecordFactory.record(for: message, modifiedAt: base)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 0)
        XCTAssertEqual(result.chunks, 0)
        let logged = await f.feed.loggedUnknownKinds
        XCTAssertTrue(logged.isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    // MARK: - Heartbeat routing + liveness math

    func testHeartbeatRoutedToStore() async throws {
        let f = try makeFixtures()
        let heartbeat = HeartbeatPayload(updatedAt: base, appVersion: "1.0.0")
        try await f.transport.save([try CloudRecordFactory.record(for: heartbeat, modifiedAt: base)])

        _ = try await f.feed.pollOnce()

        XCTAssertEqual(try f.store.heartbeatAge(now: base.addingTimeInterval(300)), .seconds(300))
    }

    func testHeartbeatNeverSeenMeansUnreachable() async throws {
        let f = try makeFixtures()

        XCTAssertNil(try f.store.heartbeatAge(now: base))
        XCTAssertFalse(f.feed.isDesktopReachable(now: base))
    }

    func testDesktopReachableWithinTwelveMinutes() async throws {
        let f = try makeFixtures()
        try await f.transport.save([
            try CloudRecordFactory.record(for: HeartbeatPayload(updatedAt: base, appVersion: "1.0.0"), modifiedAt: base)
        ])
        _ = try await f.feed.pollOnce()

        XCTAssertTrue(f.feed.isDesktopReachable(now: base.addingTimeInterval(5 * 60)))
        // Boundary: stale means STRICTLY older than 12 min (spec §2).
        XCTAssertTrue(f.feed.isDesktopReachable(now: base.addingTimeInterval(12 * 60)))
        XCTAssertFalse(f.feed.isDesktopReachable(now: base.addingTimeInterval(12 * 60 + 1)))
    }

    // MARK: - Unknown kinds / undecodable payloads

    func testUnknownKindIgnoredAndLoggedOncePerKind() async throws {
        let f = try makeFixtures()
        func mystery(_ name: String) -> CloudRecord {
            CloudRecord(recordName: name, zone: .relay, kind: "mystery", modifiedAt: base, payload: Data("?".utf8))
        }
        try await f.transport.save([mystery("mystery-1")])

        let first = try await f.feed.pollOnce()
        XCTAssertEqual(first.echoes, 0)
        XCTAssertEqual(first.chunks, 0)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))

        // A second record of the same unknown kind must not log again —
        // the once-per-kind set already contains it.
        try await f.transport.save([mystery("mystery-2")])
        _ = try await f.feed.pollOnce()
        let logged = await f.feed.loggedUnknownKinds
        XCTAssertEqual(logged, ["mystery"])
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 2))
    }

    func testUndecodableKnownKindPayloadSkippedAndTokenStillAdvances() async throws {
        // Garbage payloads of KNOWN kinds must never wedge the feed: log,
        // skip, keep routing the rest of the batch, advance the token.
        let assembler = RecordingAssembler()
        let f = try makeFixtures(assembler: assembler)
        let garbage = Data("not json".utf8)
        try await f.transport.save([
            CloudRecord(recordName: "action-X", zone: .relay, kind: RelayRecordKind.action.rawValue,
                        modifiedAt: base, payload: garbage),
            CloudRecord(recordName: "chatchunk-X-0", zone: .relay, kind: RelayRecordKind.chatChunk.rawValue,
                        modifiedAt: base, payload: garbage),
            try CloudRecordFactory.record(for: HeartbeatPayload(updatedAt: base, appVersion: "1.0.0"), modifiedAt: base)
        ])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 0)
        XCTAssertEqual(result.chunks, 0)
        let received = await assembler.chunks
        XCTAssertTrue(received.isEmpty)
        // The valid heartbeat in the same batch still routed.
        XCTAssertEqual(try f.store.heartbeatAge(now: base), .seconds(0))
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 3))

        // Token advanced past the garbage: the next poll sees nothing.
        let again = try await f.feed.pollOnce()
        XCTAssertEqual(again.echoes, 0)
        XCTAssertEqual(again.chunks, 0)
    }

    // MARK: - Token persistence + monotonic guard

    func testTokenPersistsAndBatchIsNotRedelivered() async throws {
        let assembler = RecordingAssembler()
        let f = try makeFixtures(assembler: assembler)
        try await f.transport.save([try CloudRecordFactory.record(for: chunk(), modifiedAt: base)])

        _ = try await f.feed.pollOnce()
        _ = try await f.feed.pollOnce()

        // Delivered exactly once across the two polls.
        let received = await assembler.chunks
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    func testStaleBatchDroppedWholesaleBeforeRouting() async throws {
        // Monotonic drop mirrors the replica: a batch whose token is not
        // newer than the stored one must not be routed at all — replaying
        // records would re-fire echo/heartbeat side effects.
        let assembler = RecordingAssembler()
        let f = try makeFixtures(assembler: assembler)
        XCTAssertTrue(try f.store.setRelayToken(CloudChangeToken(value: 100)))
        try await f.transport.save([try CloudRecordFactory.record(for: chunk(), modifiedAt: base)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 0)
        XCTAssertEqual(result.chunks, 0)
        let received = await assembler.chunks
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 100))
    }

    func testSetRelayTokenIsMonotonic() throws {
        let store = try ReplicaStore.inMemory()

        XCTAssertTrue(try store.setRelayToken(CloudChangeToken(value: 5)))
        XCTAssertFalse(try store.setRelayToken(CloudChangeToken(value: 3)))
        XCTAssertFalse(try store.setRelayToken(CloudChangeToken(value: 5)))
        XCTAssertEqual(try store.relayToken(), CloudChangeToken(value: 5))
        XCTAssertTrue(try store.setRelayToken(CloudChangeToken(value: 6)))
        XCTAssertEqual(try store.relayToken(), CloudChangeToken(value: 6))
    }

    func testRelayTokenIsIndependentOfDataToken() throws {
        // Decision 3: RelayFeed's cursor lives beside (not on top of) the
        // replica's data-zone cursor in replica_meta.
        let store = try ReplicaStore.inMemory()
        try store.setRelayToken(CloudChangeToken(value: 7))

        XCTAssertNil(try store.storedToken())
        XCTAssertEqual(try store.relayToken(), CloudChangeToken(value: 7))
    }

    // MARK: - Pull hook

    func testPullHookRunsBeforeChangesAreRead() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: transport, store: store)
        let record = try CloudRecordFactory.record(
            for: HeartbeatPayload(updatedAt: base, appVersion: "1.0.0"), modifiedAt: base
        )
        // The pull hook lands the record; pollOnce sees it in the same cycle
        // only if pull ran before changes().
        let feed = RelayFeed(transport: transport, store: store, outbox: outbox) {
            try await transport.save([record])
        }

        _ = try await feed.pollOnce()

        XCTAssertEqual(try store.heartbeatAge(now: base), .seconds(0))
    }

    // MARK: - Reentrancy coalescing

    /// Transport whose `changes` blocks on an external gate and counts calls,
    /// so two concurrent polls can be forced to overlap (template: ReplicaTests).
    private actor GatedTransport: CloudSyncTransport {
        private let inner = InMemoryCloudTransport()
        private(set) var changesCalls = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func seed(_ records: [CloudRecord]) async throws { try await inner.save(records) }

        func openGate() {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {
            try await inner.delete(recordNames: recordNames, in: zone)
        }

        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            changesCalls += 1
            await withCheckedContinuation { waiters.append($0) }
            return try await inner.changes(in: zone, since: token)
        }
    }

    func testConcurrentPollOnceCoalescesIntoOneCycle() async throws {
        let transport = GatedTransport()
        try await transport.seed([
            try CloudRecordFactory.record(for: HeartbeatPayload(updatedAt: base, appVersion: "1.0.0"), modifiedAt: base)
        ])
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: transport, store: store)
        let feed = RelayFeed(transport: transport, store: store, outbox: outbox)

        async let first = feed.pollOnce()
        async let second = feed.pollOnce()
        // Let both calls enter and the first suspend inside changes().
        try await Task.sleep(for: .milliseconds(50))
        await transport.openGate()

        let (a, b) = try await (first, second)
        XCTAssertEqual(a.echoes, b.echoes)
        XCTAssertEqual(a.chunks, b.chunks)
        // Coalesced: exactly one real cycle ran, so changes() was hit once.
        let calls = await transport.changesCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - onActionApplied hook

    func testOnActionAppliedFiresAfterTokenIsPersisted() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: transport, store: store)
        let fired = expectation(description: "hook fired")
        let tokenAtFire = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let hook: @Sendable () async -> Void = {
            // try? flattens relayToken's own nil into the same branch.
            if let token = try? store.relayToken() {
                tokenAtFire.withLock { $0 = token.value }
            }
            fired.fulfill()
        }
        let feed = RelayFeed(transport: transport, store: store, outbox: outbox, onActionApplied: hook)
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(store.pendingActions().first).action
        try await transport.save([try echoRecord(action, status: .applied)])

        _ = try await feed.pollOnce()

        await fulfillment(of: [fired], timeout: 5)
        // The hook exists to trigger re-hydration (Task 6); it must observe
        // the already-persisted token, never a pre-batch one.
        XCTAssertEqual(tokenAtFire.withLock { $0 }, 2)
    }

    func testOnActionAppliedNotFiredForPendingOrFailedEchoes() async throws {
        let hookCalls = OSAllocatedUnfairLock(initialState: 0)
        let fired = expectation(description: "hook fired for the applied echo")
        let hook: @Sendable () async -> Void = {
            hookCalls.withLock { $0 += 1 }
            fired.fulfill()
        }
        let f = try makeFixtures(onActionApplied: hook)

        // Own pending enqueue echo: no fire.
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        _ = try await f.feed.pollOnce()
        // Failed echo: no fire.
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.transport.save([try echoRecord(action, status: .failed, errorMessage: "no")])
        _ = try await f.feed.pollOnce()
        // Applied echo: exactly this one fires.
        try await f.transport.save([try echoRecord(action, status: .applied)])
        _ = try await f.feed.pollOnce()

        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(hookCalls.withLock { $0 }, 1)
    }

    func testTwoAppliedEchoesInOneBatchFireHookExactlyOnce() async throws {
        // One fire per batch is enough — the consumer re-hydrates everything
        // anyway. The expectation's default assertForOverFulfill turns a
        // second fire into a failure.
        let hookCalls = OSAllocatedUnfairLock(initialState: 0)
        let fired = expectation(description: "hook fired once for the whole batch")
        let hook: @Sendable () async -> Void = {
            hookCalls.withLock { $0 += 1 }
            fired.fulfill()
        }
        let f = try makeFixtures(onActionApplied: hook)
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        _ = try await f.outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-2")
        _ = try await f.feed.pollOnce() // consume the two own-pending reflections
        for pending in try f.store.pendingActions() {
            try await f.transport.save([try echoRecord(pending.action, status: .applied)])
        }

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result.echoes, 2)
        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(hookCalls.withLock { $0 }, 1)
    }

    /// Gate the hook can hang on, so the test can prove a slow hook never
    /// blocks the feed.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    func testSlowHookDoesNotBlockPollOnceOrTheNextPoll() async throws {
        let gate = Gate()
        let finished = expectation(description: "slow hook eventually finished")
        let hook: @Sendable () async -> Void = {
            await gate.wait()
            finished.fulfill()
        }
        let f = try makeFixtures(onActionApplied: hook)
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.transport.save([try echoRecord(action, status: .applied)])

        // pollOnce returns while the hook is still hung on the gate
        // (fire-and-forget), and the NEXT poll runs to completion too.
        let first = try await f.feed.pollOnce()
        XCTAssertEqual(first.echoes, 1)
        try await f.transport.save([
            try CloudRecordFactory.record(for: HeartbeatPayload(updatedAt: base, appVersion: "1.0.0"), modifiedAt: base)
        ])
        _ = try await f.feed.pollOnce()
        XCTAssertEqual(try f.store.heartbeatAge(now: base), .seconds(0))

        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
    }
}
