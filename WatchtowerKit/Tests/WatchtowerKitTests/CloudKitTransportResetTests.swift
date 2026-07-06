import XCTest
@testable import WatchtowerKit

final class CloudKitTransportResetTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ name: String, zone: CloudZoneID = .data) -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "target", modifiedAt: stamp, payload: Data("{}".utf8))
    }

    /// Sendable counter for the @Sendable reset handler.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func testAccountResetWipesStoreCountsAndFiresHandler() async throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1")])
        try store.enqueueSave([record("target-2")])
        try store.saveSystemFields(Data("f".utf8), recordName: "target-1", zone: .data)
        try store.saveEngineState(Data("s".utf8))

        let transport = CloudKitTransport(store: store)
        let counter = Counter()
        await transport.setAccountResetHandler { counter.increment() }

        await transport.resetForAccountChange()

        let firstCount = await transport.accountResetCount
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(counter.count, 1, "handler must fire so the hub can wipe its sync state")

        // The store was wiped as part of the reset.
        XCTAssertTrue(try store.changes(in: .data, since: nil).changed.isEmpty)
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty)
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))
        XCTAssertNil(try store.loadEngineState())

        // A second reset increments again (each account switch is recorded).
        await transport.resetForAccountChange()
        let secondCount = await transport.accountResetCount
        XCTAssertEqual(secondCount, 2)
        XCTAssertEqual(counter.count, 2)
    }
}
