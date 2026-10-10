import CloudKit
import XCTest
@testable import WatchtowerSync

/// `stop()`: the Mac owner turned the hub off, so the engine is cancelled
/// and dropped, nothing reaches it any more, and `start()` builds a new one.
final class CloudKitTransportStopTests: XCTestCase {
    private final class EngineFactoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var engines: [FakeSyncEngine] = []
        func make() -> FakeSyncEngine {
            let engine = FakeSyncEngine()
            lock.withLock { engines.append(engine) }
            return engine
        }
        var built: [FakeSyncEngine] { lock.withLock { engines } }
    }

    private func record(_ name: String) -> CloudRecord {
        CloudRecord(recordName: name, zone: .data, kind: "workbench", modifiedAt: Date(), payload: Data("{}".utf8))
    }

    func testStopCancelsAndDropsTheEngineAndStartBuildsANewOne() async throws {
        let log = EngineFactoryLog()
        let store = try TransportStore.inMemory()
        let transport = CloudKitTransport(
            store: store, scope: .private, entitlementPresent: { true },
            engineFactory: { _, _ in log.make() }, now: { Date() }, sleep: { _ in }
        )
        await transport.start()
        let first = try XCTUnwrap(log.built.first)

        await transport.stop()
        try await transport.save([record("workbench-1")])
        try await transport.pull()

        XCTAssertEqual(first.cancelCount, 1, "the engine's operations are cancelled")
        XCTAssertTrue(first.recordZoneChanges.isEmpty, "a save after stop() never reaches the old engine")
        XCTAssertEqual(first.fetchCount, 0, "a pull after stop() fetches nothing")
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["workbench-1"], "the save waits in the store")

        await transport.start()
        XCTAssertEqual(log.built.count, 2, "start() after stop() builds a new engine")
        XCTAssertFalse(log.built[1].recordZoneChanges.isEmpty, "the waiting save is scheduled on the new engine")
    }

    func testAQueuedResetRelaunchNeverRevivesAStoppedTransport() async throws {
        let log = EngineFactoryLog()
        let transport = CloudKitTransport(
            store: try .inMemory(), scope: .private, entitlementPresent: { true },
            engineFactory: { _, _ in log.make() }, now: { Date() }, sleep: { _ in }
        )
        await transport.start()

        // An account change schedules a relaunch; the owner turns the hub off
        // before it ran.
        await transport.resetForAccountChange()
        let relaunch = await transport.restartTask
        await transport.stop()
        await relaunch?.value

        let stopped = await transport.isStopped
        XCTAssertTrue(stopped)
        try await transport.save([record("workbench-1")])
        for engine in log.built {
            XCTAssertTrue(engine.recordZoneChanges.isEmpty, "no live engine is left after stop()")
        }
        XCTAssertTrue(log.built.dropFirst().allSatisfy { $0.cancelCount > 0 }, "an engine the relaunch built is cancelled")

        await transport.start()
        let afterStart = await transport.isStopped
        XCTAssertFalse(afterStart, "only the public start() clears the stop")
        XCTAssertFalse(try XCTUnwrap(log.built.last).recordZoneChanges.isEmpty, "the restarted engine takes the waiting save")
    }

    func testStopClearsTheThrottleSoARestartSendsAtOnce() async throws {
        let transport = await CloudKitTransport.testing(store: try .inMemory()) { _ in
            // The retry never fires: only stop()/start() may end the throttle.
            try? await Task.sleep(for: .seconds(3_600))
        }
        try await transport.save([record("workbench-1")])
        await transport.handleSendError(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 600.0]))
        let throttled = await transport.nextEngineBatch()
        XCTAssertNil(throttled, "throttled: nothing is sent")

        await transport.stop()
        await transport.start()

        let batch = await transport.nextEngineBatch()
        XCTAssertNotNil(batch, "after a restart the pending save goes out without waiting for an old deadline")
        let since = await transport.throttledSince
        XCTAssertNil(since)
    }
}

/// `sendNow()`: the hub's fast lane asks for an immediate send; it never
/// overrides a stop, a throttle wait or a quota pause.
final class CloudKitTransportSendNowTests: XCTestCase {
    private func record(_ name: String) -> CloudRecord {
        CloudRecord(recordName: name, zone: .data, kind: "terminal_session", modifiedAt: Date(), payload: Data("{}".utf8))
    }

    func testSendNowAsksTheEngineToSendThePendingQueue() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        try await transport.save([record("terminal_session-1")])

        await transport.sendNow()

        XCTAssertEqual(engine.sendCount, 1)
        XCTAssertFalse(engine.recordZoneChanges.isEmpty, "the pending save is scheduled on the engine")
    }

    func testSendNowIsANoOpWhileThrottled() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine) { _ in
            // The retry never fires inside the test: the wait stays open.
            try? await Task.sleep(for: .seconds(3_600))
        }
        addTeardownBlock { await transport.retryTask?.cancel() }
        try await transport.save([record("terminal_session-1")])
        await transport.handleSendError(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 600.0]))

        await transport.sendNow()

        XCTAssertEqual(engine.sendCount, 0, "a server-requested wait is honoured")
    }

    func testSendNowIsANoOpAfterStop() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        try await transport.save([record("terminal_session-1")])
        await transport.stop()

        await transport.sendNow()

        XCTAssertEqual(engine.sendCount, 0, "a stopped transport sends nothing")
    }
}
