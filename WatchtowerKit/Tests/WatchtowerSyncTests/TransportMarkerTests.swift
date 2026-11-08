import Foundation
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The hub's transport marker (relay client Phase 3, sim rule 12a; Go hub Phase 3 contract point 4): the latest
/// `transport_switched` without `keybox` and `device_id`, decoded only when every field the phone follows is there,
/// and handed to the follower by the hydrator while the record stays stored.
final class TransportMarkerTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private var full: [String: Any] {
        [
            "id": "DDDDDDDD-0000-4000-8000-000000000004", "kind": "transport_switched",
            "hub_id": TestE2E.hubID.uuidString, "target": "relay", "epoch": 3, "by": TestE2E.deviceID.uuidString,
            "at": 1_800_000_000
        ]
    }

    func testDecode() throws {
        let marker = try TransportMarker.decode(try json(full))
        XCTAssertEqual(marker, TransportMarker(
            target: .relay, epoch: 3, by: TestE2E.deviceID.uuidString, at: Date(timeIntervalSince1970: 1_800_000_000)))

        var back = full
        back["target"] = "cloudkit"
        back["by"] = "entitlement_expired"
        let cloud = try TransportMarker.decode(try json(back))
        XCTAssertEqual(cloud.target, .cloudKit)
        XCTAssertEqual(cloud.by, "entitlement_expired")
        XCTAssertEqual(TransportMarker.recordName, "\(TransportMarker.kind)-marker")
    }

    func testAnUnknownTargetIsRefused() throws {
        var body = full
        body["target"] = "carrier_pigeon"
        XCTAssertThrowsError(try TransportMarker.decode(try json(body))) { error in
            XCTAssertEqual(error as? TransportMarkerError, .unknownTarget("carrier_pigeon"))
        }
    }

    func testMissingFieldsAreRefused() throws {
        for field in ["target", "epoch", "by", "at"] {
            var body = full
            body[field] = nil
            XCTAssertThrowsError(try TransportMarker.decode(try json(body)), field) { error in
                XCTAssertEqual(error as? TransportMarkerError, .missingField(field), field)
            }
        }
    }

    /// The hydrator stores the marker like any data record and hands it over once per new payload; a payload that
    /// does not decode is never handed.
    func testTheHydratorHandsTheMarkerOverAndStoresIt() async throws {
        let keys = try TestE2E.phoneStore()
        let inner = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let seen = MarkerLog()
        let hydrator = ReplicaHydrator(transport: inner, store: store) { marker in
            await seen.add(marker)
            return true
        }
        // Sealed as the Go hub seals it: the Swift hub's `SecureTransport` seals only kinds it publishes.
        let record = { (body: [String: Any], seq: UInt64) throws -> CloudRecord in
            try TestE2E.sealedDataRecord(
                CloudRecord(
                    recordName: TransportMarker.recordName, zone: .data, kind: TransportMarker.kind, modifiedAt: Date(),
                    payload: try self.json(body)),
                seq: seq)
        }

        try await inner.save([try record(full, 1)])
        _ = try await hydrator.hydrateOnce()
        _ = try await hydrator.hydrateOnce()
        var markers = await seen.all
        XCTAssertEqual(markers.map(\.epoch), [3], "handed once")
        let stored = try await store.reader.read { db in try store.payload(forRecordName: TransportMarker.recordName, from: db) }
        XCTAssertNotNil(stored, "still stored")

        var unknown = full
        unknown["target"] = "carrier_pigeon"
        unknown["epoch"] = 4
        try await inner.save([try record(unknown, 2)])
        _ = try await hydrator.hydrateOnce()
        markers = await seen.all
        XCTAssertEqual(markers.map(\.epoch), [3], "an unknown target is never handed")
    }
}

private actor MarkerLog {
    private(set) var all: [TransportMarker] = []

    func add(_ marker: TransportMarker) {
        all.append(marker)
    }
}
