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
}
