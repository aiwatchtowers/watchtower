import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// `onRecordsApplied` reports what `indexPending` opened (F10, F11): the plain record name, the typed kind and the
/// frame's notify level. Rows stored while the keys were locked are reported by the first cycle after unlock.
final class ReplicaHydratorTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func slice(_ kind: SliceKind, id: String, notifyLevel: String? = nil, modifiedAt: Date? = nil) -> CloudRecord {
        CloudRecord(
            recordName: kind.recordName(id: id), zone: .data, kind: kind.rawValue, modifiedAt: modifiedAt ?? stamp,
            payload: Data("{\"id\":\(id)}".utf8), notifyLevel: notifyLevel)
    }

    func testOnRecordsAppliedReportsIndexedRecordsAndLockedOnesAfterUnlock() async throws {
        let keys = try TestE2E.phoneStore()
        keys.isLocked = true
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let transport = TestE2E.hubTransport()
        let reported = OSAllocatedUnfairLock(initialState: [[AppliedSliceRecord]]())
        let hook: @Sendable ([AppliedSliceRecord]) -> Void = { records in reported.withLock { $0.append(records) } }
        let hydrator = ReplicaHydrator(transport: transport, store: store, onRecordsApplied: hook)

        let urgentAt = stamp.addingTimeInterval(60)
        try await transport.save([
            slice(.ownerAsk, id: "7", notifyLevel: "urgent", modifiedAt: urgentAt),
            slice(.target, id: "3")
        ])
        let locked = try await hydrator.hydrateOnce()
        XCTAssertEqual(locked.applied, 2)
        XCTAssertTrue(reported.withLock { $0 }.isEmpty, "nothing is reported before it can be opened")

        keys.isLocked = false
        _ = try await hydrator.hydrateOnce()
        let batches = reported.withLock { $0 }
        XCTAssertEqual(batches.count, 1)
        let records = try XCTUnwrap(batches.first).sorted { $0.recordName < $1.recordName }
        XCTAssertEqual(records, [
            AppliedSliceRecord(recordName: "owner_ask-7", kind: .ownerAsk, notifyLevel: "urgent", modifiedAt: urgentAt),
            AppliedSliceRecord(recordName: "target-3", kind: .target, notifyLevel: nil, modifiedAt: stamp)
        ])

        // An unlocked cycle reports what it applies right away, and nothing twice.
        try await transport.save([slice(.ownerAsk, id: "8", notifyLevel: "urgent")])
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(reported.withLock { $0 }.last?.map(\.recordName), ["owner_ask-8"])
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(reported.withLock { $0 }.count, 2)
    }

    func testAppliedCountsOnlyTheRecordsTheReplicaStored() async throws {
        let inner = InMemoryCloudTransport()
        let hub = TestE2E.hub()
        hub.link(TestE2E.strangerIdentity)
        let sealer = TestE2E.hubTransport(hub)
        try await inner.save([
            try await sealer.seal(slice(.target, id: "1")),
            try await sealer.seal(TestE2E.keyboxRecord(deviceID: TestE2E.strangerDeviceID, modifiedAt: stamp)),
            try TestE2E.sealedDataRecord(slice(.target, id: "2"), seq: 50, signer: TestE2E.strangerIdentity.signing),
            CloudRecord(recordName: "sig-abc", zone: .data, kind: WireKind.signal, modifiedAt: stamp, payload: Data())
        ])
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())

        let result = try await ReplicaHydrator(transport: inner, store: store).hydrateOnce()

        XCTAssertEqual(result.applied, 1, "refused, other-phone keybox and signal records are not counted")
        XCTAssertEqual(store.rejectedCount(), 1)
    }
}
