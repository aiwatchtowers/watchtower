import XCTest
@testable import WatchtowerKit

final class TransportStoreTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ name: String, zone: CloudZoneID = .data, payload: String = "{}") -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "target", modifiedAt: stamp, payload: Data(payload.utf8))
    }

    func testChangesMirrorInMemorySemantics() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1"), record("target-2")])
        let first = try store.changes(in: .data, since: nil)
        XCTAssertEqual(first.changed.map(\.recordName), ["target-1", "target-2"])

        try store.bufferChanged([record("target-3")])
        let second = try store.changes(in: .data, since: first.newToken)
        XCTAssertEqual(second.changed.map(\.recordName), ["target-3"])

        let third = try store.changes(in: .data, since: second.newToken)
        XCTAssertTrue(third.changed.isEmpty)
        XCTAssertEqual(third.newToken, second.newToken)
    }

    func testLatestEventWinsIncludingDeleteThenResave() throws {
        let store = try TransportStore.inMemory()
        try store.bufferDeleted(recordNames: ["target-1"], zone: .data)
        try store.bufferChanged([record("target-1", payload: "{\"v\":2}")])
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(batch.changed[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testZonesIsolatedInBuffer() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1", zone: .data)])
        try store.bufferChanged([record("action-1", zone: .relay)])
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["action-1"])
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["target-1"])
    }

    func testPendingUpsertLatestWriteWins() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1", payload: "{\"v\":1}")])
        try store.enqueueSave([record("target-1", payload: "{\"v\":2}")])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.count, 1)
        XCTAssertEqual(batch.saves[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletes.isEmpty)
    }

    func testDeleteReplacesPendingSaveForSameName() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1")])
        try store.enqueueDelete(recordNames: ["target-1"], zone: .data)
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertTrue(batch.saves.isEmpty)
        XCTAssertEqual(batch.deletes.map(\.name), ["target-1"])
    }

    func testClearPendingRemovesOnlyNamed() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1"), record("target-2")])
        try store.clearPending(saves: [(name: "target-1", zone: .data, sentModifiedAt: .distantFuture)], deletes: [])
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["target-2"])
    }

    func testClearPendingIsZoneScoped() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("shared-name", zone: .data)])
        try store.enqueueSave([record("shared-name", zone: .relay)])
        try store.clearPending(saves: [(name: "shared-name", zone: .data, sentModifiedAt: .distantFuture)], deletes: [])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.map(\.recordName), ["shared-name"])
        XCTAssertEqual(batch.saves[0].zone, .relay)
    }

    func testClearPendingKeepsNewerReEnqueuedSave() throws {
        let store = try TransportStore.inMemory()
        let v1Stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let v2Stamp = Date(timeIntervalSince1970: 1_700_000_100)
        let v1 = CloudRecord(recordName: "target-1", zone: .data, kind: "target", modifiedAt: v1Stamp, payload: Data("{\"v\":1}".utf8))
        try store.enqueueSave([v1])
        // v2 lands while v1 is in flight
        let v2 = CloudRecord(recordName: "target-1", zone: .data, kind: "target", modifiedAt: v2Stamp, payload: Data("{\"v\":2}".utf8))
        try store.enqueueSave([v2])
        // v1's send completes
        try store.clearPending(saves: [(name: "target-1", zone: .data, sentModifiedAt: v1Stamp)], deletes: [])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.map(\.recordName), ["target-1"], "newer pending save must survive the clear")
        XCTAssertEqual(batch.saves[0].payload, Data("{\"v\":2}".utf8))
    }

    func testInterleavedZoneWritesDoNotSkipOrDuplicate() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1", zone: .data)])      // seq 1
        let dataToken = try store.changes(in: .data, since: nil).newToken
        try store.bufferChanged([record("action-1", zone: .relay)])     // seq 2
        try store.bufferChanged([record("target-2", zone: .data)])      // seq 3

        let batch = try store.changes(in: .data, since: dataToken)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-2"])

        let after = try store.changes(in: .data, since: batch.newToken)
        XCTAssertTrue(after.changed.isEmpty)
        XCTAssertTrue(after.deletedRecordNames.isEmpty)
    }

    func testSystemFieldsRoundTrip() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))

        try store.saveSystemFields(Data("fields-v1".utf8), recordName: "target-1", zone: .data)
        XCTAssertEqual(try store.systemFields(recordName: "target-1", zone: .data), Data("fields-v1".utf8))

        // Re-save overwrites (server record changed → newer fields win).
        try store.saveSystemFields(Data("fields-v2".utf8), recordName: "target-1", zone: .data)
        XCTAssertEqual(try store.systemFields(recordName: "target-1", zone: .data), Data("fields-v2".utf8))

        try store.deleteSystemFields(recordNames: ["target-1"], zone: .data)
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))
    }

    func testSystemFieldsAreZoneScoped() throws {
        let store = try TransportStore.inMemory()
        try store.saveSystemFields(Data("data-zone".utf8), recordName: "shared-name", zone: .data)
        try store.saveSystemFields(Data("relay-zone".utf8), recordName: "shared-name", zone: .relay)
        XCTAssertEqual(try store.systemFields(recordName: "shared-name", zone: .data), Data("data-zone".utf8))
        XCTAssertEqual(try store.systemFields(recordName: "shared-name", zone: .relay), Data("relay-zone".utf8))

        try store.deleteSystemFields(recordNames: ["shared-name"], zone: .data)
        XCTAssertNil(try store.systemFields(recordName: "shared-name", zone: .data))
        XCTAssertEqual(try store.systemFields(recordName: "shared-name", zone: .relay), Data("relay-zone".utf8))
    }

    func testDeleteSystemFieldsRemovesOnlyNamed() throws {
        let store = try TransportStore.inMemory()
        try store.saveSystemFields(Data("a".utf8), recordName: "target-1", zone: .data)
        try store.saveSystemFields(Data("b".utf8), recordName: "target-2", zone: .data)
        try store.deleteSystemFields(recordNames: ["target-1", "never-saved"], zone: .data)
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))
        XCTAssertEqual(try store.systemFields(recordName: "target-2", zone: .data), Data("b".utf8))
    }

    func testEngineStateRoundTrip() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(try store.loadEngineState())
        try store.saveEngineState(Data("state-blob".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("state-blob".utf8))
        try store.saveEngineState(Data("state-blob-2".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("state-blob-2".utf8))
    }
}
