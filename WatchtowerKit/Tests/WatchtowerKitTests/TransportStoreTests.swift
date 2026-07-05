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
        try store.clearPending(saveNames: ["target-1"], deleteNames: [])
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["target-2"])
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
