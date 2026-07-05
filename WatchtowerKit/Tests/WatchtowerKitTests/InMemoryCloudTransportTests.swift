import XCTest
@testable import WatchtowerKit

final class InMemoryCloudTransportTests: XCTestCase {
    private func record(_ name: String, zone: CloudZoneID = .data, kind: String = "target", payload: String = "{}") -> CloudRecord {
        CloudRecord(
            recordName: name,
            zone: zone,
            kind: kind,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data(payload.utf8)
        )
    }

    func testSavedRecordsAppearInChanges() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1"), record("target-2")])

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName).sorted(), ["target-1", "target-2"])
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testChangesSinceTokenReturnsOnlyNewEvents() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1")])
        let first = try await transport.changes(in: .data, since: nil)

        try await transport.save([record("target-2")])
        let second = try await transport.changes(in: .data, since: first.newToken)
        XCTAssertEqual(second.changed.map(\.recordName), ["target-2"])

        let third = try await transport.changes(in: .data, since: second.newToken)
        XCTAssertTrue(third.changed.isEmpty)
        XCTAssertEqual(third.newToken, second.newToken)
    }

    func testLatestWriteWinsWithinABatch() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1", payload: "{\"v\":1}")])
        try await transport.save([record("target-1", payload: "{\"v\":2}")])

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.count, 1)
        XCTAssertEqual(batch.changed[0].payload, Data("{\"v\":2}".utf8))
    }

    func testDeleteProducesTombstoneAndSuppressesEarlierSave() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1")])
        try await transport.delete(recordNames: ["target-1"], in: .data)

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertEqual(batch.deletedRecordNames, ["target-1"])
    }

    func testZonesAreIsolated() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1", zone: .data)])
        try await transport.save([record("action-1", zone: .relay, kind: "action")])

        let dataBatch = try await transport.changes(in: .data, since: nil)
        let relayBatch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(dataBatch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(relayBatch.changed.map(\.recordName), ["action-1"])
    }

    func testDataZoneTokenUnaffectedByRelayWrites() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1", zone: .data)])
        let dataToken = try await transport.changes(in: .data, since: nil).newToken

        try await transport.save([record("action-1", zone: .relay, kind: "action")])
        let batch = try await transport.changes(in: .data, since: dataToken)
        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testResaveAfterDeleteWithinOneTokenWindowYieldsRecordNotTombstone() async throws {
        // Latest event per recordName wins in BOTH orders: a re-save after a
        // delete must surface the record and suppress the tombstone, matching
        // what a CloudKit zone-changes delta reports for a recreated record.
        let transport = InMemoryCloudTransport()
        try await transport.delete(recordNames: ["target-1"], in: .data)
        try await transport.save([record("target-1", payload: "{\"v\":2}")])

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(batch.changed[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }
}
