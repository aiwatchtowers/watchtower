import XCTest
import GRDB
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class SliceDiffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewRowsBecomeUpserts() throws {
        let result = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: Row(["id": 1, "text": "a"]))],
            knownHashes: [:],
            now: now
        )
        XCTAssertEqual(result.upserts.map(\.recordName), ["target-1"])
        XCTAssertTrue(result.deletions.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testUnchangedRowProducesNothing() throws {
        let row = Row(["id": 1, "text": "a"])
        let first = SliceDiff.compute(kind: .target, rows: [(id: "1", row: row)], knownHashes: [:], now: now)
        let payload = first.upserts[0].payload
        let hash = SliceDiff.hashHex(payload)

        let second = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: row)],
            knownHashes: ["target-1": hash],
            now: now
        )
        XCTAssertTrue(second.upserts.isEmpty)
        XCTAssertTrue(second.deletions.isEmpty)
    }

    func testChangedRowProducesUpsert() throws {
        let result = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: Row(["id": 1, "text": "b"]))],
            knownHashes: ["target-1": "stale-hash"],
            now: now
        )
        XCTAssertEqual(result.upserts.map(\.recordName), ["target-1"])
    }

    func testVanishedRowBecomesDeletion() throws {
        let result = SliceDiff.compute(
            kind: .target,
            rows: [],
            knownHashes: ["target-1": "h1", "target-2": "h2"],
            now: now
        )
        XCTAssertEqual(result.deletions, ["target-1", "target-2"])
        XCTAssertTrue(result.upserts.isEmpty)
    }

    func testNonFiniteDoubleRowIsSkippedNotFatal() throws {
        let bad = Row(["id": 1, "score": Double.infinity])
        let good = Row(["id": 2, "text": "ok"])
        let result = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: bad), (id: "2", row: good)],
            knownHashes: [:],
            now: now
        )
        XCTAssertEqual(result.skipped, ["target-1"])
        XCTAssertEqual(result.upserts.map(\.recordName), ["target-2"])
    }

    func testHubSyncStateRoundTrip() throws {
        let state = try HubSyncState.inMemory()
        try state.setHash("h1", for: "target-1")
        try state.setHash("h2", for: "inbox_item-5")
        XCTAssertEqual(try state.hashes(forKind: .target), ["target-1": "h1"])
        try state.removeHashes(["target-1"])
        XCTAssertEqual(try state.hashes(forKind: .target), [:])
        XCTAssertEqual(try state.hashes(forKind: .inboxItem), ["inbox_item-5": "h2"])
    }
}
