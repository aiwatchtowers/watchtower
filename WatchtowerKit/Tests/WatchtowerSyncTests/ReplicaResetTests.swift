import GRDB
import XCTest
@testable import WatchtowerSync

/// `resetSyncTokens` and `payload(forRecordName:from:)`: a transport whose
/// cursor restarts (a new in-memory demo transport per launch) lands its
/// records on a persisted replica only after the reset.
final class ReplicaResetTests: XCTestCase {
    private func heartbeatRecord(at stamp: Date) throws -> CloudRecord {
        try CloudRecordFactory.record(for: HeartbeatFixtures.minimal(updatedAt: stamp), modifiedAt: stamp)
    }

    private func storedStamp(in store: ReplicaStore) throws -> Date? {
        let payload = try store.reader.read { db in
            try store.payload(forRecordName: HeartbeatPayload.recordName, from: db)
        }
        return try payload.map { try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: $0).updatedAt }
    }

    func testARestartedTransportLandsOnlyAfterTheReset() async throws {
        let store = try ReplicaStore.inMemory()
        let first = Date().addingTimeInterval(-3_600).rounded()
        let second = Date().rounded()

        let launch1 = InMemoryCloudTransport()
        try await launch1.save([try heartbeatRecord(at: first)])
        _ = try await ReplicaHydrator(transport: launch1, store: store).hydrateOnce()
        XCTAssertEqual(try storedStamp(in: store), first)

        // A new transport restarts its cursor at the same token value.
        let launch2 = InMemoryCloudTransport()
        try await launch2.save([try heartbeatRecord(at: second)])
        _ = try await ReplicaHydrator(transport: launch2, store: store).hydrateOnce()
        XCTAssertEqual(try storedStamp(in: store), first, "without a reset the guard drops the batch")

        try store.resetSyncTokens()
        XCTAssertNil(try store.storedToken())
        _ = try await ReplicaHydrator(transport: launch2, store: store).hydrateOnce()
        XCTAssertEqual(try storedStamp(in: store), second)
    }

    func testResetClearsTheRelayTokenAndKeepsTheWatermark() throws {
        let store = try ReplicaStore.inMemory()
        try store.setRelayToken(CloudChangeToken(value: 7))
        let watermark = Date().rounded()
        try store.setLastAlertedWatermark(watermark)

        try store.resetSyncTokens()

        XCTAssertNil(try store.relayToken())
        XCTAssertEqual(try store.lastAlertedWatermark(), watermark)
    }

    func testPayloadForAnAbsentRecordIsNil() throws {
        let store = try ReplicaStore.inMemory()
        let payload = try store.reader.read { db in try store.payload(forRecordName: "heartbeat", from: db) }
        XCTAssertNil(payload)
    }
}

private extension Date {
    /// Whole seconds: RelayCoder dates are Unix seconds.
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
