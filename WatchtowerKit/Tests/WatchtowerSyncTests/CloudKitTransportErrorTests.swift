import CloudKit
import XCTest
@testable import WatchtowerSync

/// Transport error handling (spec §9): batch halving on `.limitExceeded`,
/// retry-after backoff on `.requestRateLimited` / `.zoneBusy`, and the
/// quota pause.
final class CloudKitTransportErrorTests: XCTestCase {
    private func records(_ count: Int) -> [CloudRecord] {
        let stamp = Date()
        return (0..<count).map {
            CloudRecord(recordName: "target-\($0)", zone: .data, kind: "target", modifiedAt: stamp, payload: Data("{}".utf8))
        }
    }

    private func rejected(_ transport: CloudKitTransport) async -> Collector<String> {
        let collector = Collector<String>()
        await transport.setRecordRejectedHandler { name, _ in collector.append(name) }
        return collector
    }

    /// Sends every batch the transport hands out. A batch holding a bad
    /// record fails whole with `.limitExceeded`, the way an oversized
    /// request does; any other batch saves. Returns the batch sizes.
    private func drain(_ transport: CloudKitTransport, bad: Set<String>) async -> [Int] {
        var sizes: [Int] = []
        while let batch = await transport.nextEngineBatch(), sizes.count < 100 {
            sizes.append(batch.recordsToSave.count)
            if batch.recordsToSave.contains(where: { bad.contains($0.recordID.recordName) }) {
                await transport.handleSentChanges(
                    saved: [], deleted: [],
                    failedSaves: batch.recordsToSave.map { ($0, CKError(.limitExceeded)) },
                    failedDeletes: [:]
                )
            } else {
                await transport.handleSentChanges(saved: batch.recordsToSave, deleted: [], failedSaves: [], failedDeletes: [:])
            }
        }
        return sizes
    }

    // MARK: - limitExceeded

    func testLimitExceededHalvesTheBatchDownToTheBadRecord() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)
        let rejectedNames = await rejected(transport)
        try await transport.save(records(200))

        let sizes = await drain(transport, bad: ["target-0"])

        XCTAssertEqual(sizes, [200, 100, 50, 25, 12, 6, 3, 1, 199])
        XCTAssertEqual(rejectedNames.values, ["target-0"], "only the bad record's hash is cleared")
        XCTAssertTrue(try store.pendingBatch(limit: 500).saves.isEmpty, "everything else was sent")
    }

    func testLimitExceededOnASingleRecordDropsItWithoutRetrying() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)
        let rejectedNames = await rejected(transport)
        try await transport.save(records(1))

        let sizes = await drain(transport, bad: ["target-0"])

        XCTAssertEqual(sizes, [1])
        XCTAssertEqual(rejectedNames.values, ["target-0"])
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty)
    }

    func testBatchLimitStaysReducedWhileTheBacklogDrains() async throws {
        // Many records that are only too large together: once halved, the
        // limit holds until the queue is empty rather than bouncing back.
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)
        try await transport.save(records(120))

        var sizes: [Int] = []
        while let batch = await transport.nextEngineBatch(), sizes.count < 100 {
            sizes.append(batch.recordsToSave.count)
            if batch.recordsToSave.count > 50 {
                await transport.handleSentChanges(
                    saved: [], deleted: [],
                    failedSaves: batch.recordsToSave.map { ($0, CKError(.limitExceeded)) },
                    failedDeletes: [:]
                )
            } else {
                await transport.handleSentChanges(saved: batch.recordsToSave, deleted: [], failedSaves: [], failedDeletes: [:])
            }
        }

        XCTAssertEqual(sizes, [120, 60, 30, 30, 30, 30])
        let limit = await transport.batchLimit
        XCTAssertEqual(limit, 200, "an empty queue restores the full batch")
    }

    // MARK: - Rate limiting

    func testRetryAfterIsHonoured() async throws {
        let sleeps = Collector<TimeInterval>()
        let clock = TestClock()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine, clock: clock, sleeps: sleeps)

        await transport.handleSendError(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 7.0]))
        let since = await transport.throttledSince
        await transport.retryTask?.value

        XCTAssertEqual(sleeps.values, [7])
        XCTAssertEqual(since, clock.now)
        XCTAssertEqual(engine.sendCount, 1, "the send is retried after the wait")
    }

    func testDefaultBackoffStartsAtFiveAndDoubles() async throws {
        let sleeps = Collector<TimeInterval>()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), sleeps: sleeps)

        await transport.handleSendError(CKError(.zoneBusy))
        await transport.retryTask?.value
        await transport.handleSendError(CKError(.requestRateLimited))
        await transport.retryTask?.value

        XCTAssertEqual(sleeps.values, [5, 10])
    }

    func testBackoffCapsAt120Seconds() async throws {
        let sleeps = Collector<TimeInterval>()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), sleeps: sleeps)

        for _ in 0..<7 {
            await transport.handleSendError(CKError(.zoneBusy))
            await transport.retryTask?.value
        }

        XCTAssertEqual(sleeps.values, [5, 10, 20, 40, 80, 120, 120])
    }

    func testThrottledSinceHoldsAcrossThrottlesAndClearsOnASuccessfulSend() async throws {
        let store = try TransportStore.inMemory()
        let clock = TestClock()
        let sleeps = Collector<TimeInterval>()
        let transport = await CloudKitTransport.testing(store: store, clock: clock, sleeps: sleeps)
        let start = clock.now

        await transport.handleSendError(CKError(.zoneBusy))
        await transport.retryTask?.value
        clock.advance(61)
        await transport.handleSendError(CKError(.zoneBusy))
        await transport.retryTask?.value
        let held = await transport.throttledSince
        XCTAssertEqual(held, start, "the Settings line measures throttling from its first throttle")

        try await transport.save(records(1))
        let next = await transport.nextEngineBatch()
        let batch = try XCTUnwrap(next)
        await transport.handleSentChanges(saved: batch.recordsToSave, deleted: [], failedSaves: [], failedDeletes: [:])

        let cleared = await transport.throttledSince
        XCTAssertNil(cleared)
        await transport.handleSendError(CKError(.zoneBusy))
        await transport.retryTask?.value
        XCTAssertEqual(sleeps.values, [5, 10, 5], "a successful send resets the backoff")
    }

    func testRateLimitedFailedSavesThrottleOncePerBatch() async throws {
        let sleeps = Collector<TimeInterval>()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), sleeps: sleeps)
        try await transport.save(records(3))
        let next = await transport.nextEngineBatch()
        let batch = try XCTUnwrap(next)

        await transport.handleSentChanges(
            saved: [], deleted: [],
            failedSaves: batch.recordsToSave.map { ($0, CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 9.0])) },
            failedDeletes: [:]
        )
        await transport.retryTask?.value

        XCTAssertEqual(sleeps.values, [9])
    }

    func testRateLimitedFetchThrottlesAndSkipsPullsUntilTheWaitEnds() async throws {
        let clock = TestClock()
        let engine = FakeSyncEngine(fetchErrors: [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])])
        // A sleeper that outlasts the test keeps the throttle window open.
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine, clock: clock) {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }

        try await transport.pull()
        try await transport.pull()
        XCTAssertEqual(engine.fetchCount, 1, "no fetch while throttled")

        clock.advance(31)
        try await transport.pull()
        XCTAssertEqual(engine.fetchCount, 2)
        await transport.retryTask?.cancel()
    }

    // MARK: - quotaExceeded

    func testQuotaExceededPausesUntilResume() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: store, engine: engine)
        let collected = Collector<TransportEvent>()
        await transport.setEventHandler { collected.append($0) }
        try await transport.save(records(2))
        let next = await transport.nextEngineBatch()
        let batch = try XCTUnwrap(next)

        await transport.handleSentChanges(
            saved: [], deleted: [],
            failedSaves: batch.recordsToSave.map { ($0, CKError(.quotaExceeded)) },
            failedDeletes: [:]
        )

        XCTAssertEqual(collected.values, [.quotaExceeded], "one event per pause")
        let paused = await transport.isPaused
        XCTAssertTrue(paused)
        let whilePaused = await transport.nextEngineBatch()
        XCTAssertNil(whilePaused, "nothing is retried while paused")
        await transport.handleSendError(CKError(.zoneBusy))
        await transport.retryTask?.value
        XCTAssertEqual(engine.sendCount, 0, "a throttle retry does not lift the pause")

        await transport.resume()

        let resumed = await transport.isPaused
        XCTAssertFalse(resumed)
        XCTAssertEqual(engine.sendCount, 1)
        let afterResume = await transport.nextEngineBatch()
        XCTAssertEqual(afterResume?.recordsToSave.count, 2, "the failed records are still pending")
    }
}
