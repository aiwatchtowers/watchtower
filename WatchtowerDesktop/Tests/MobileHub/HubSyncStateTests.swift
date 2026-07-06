import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class HubSyncStateTests: XCTestCase {
    func testWipeSyncStateClearsHashesTokenAndProcessedSet() throws {
        let state = try HubSyncState.inMemory()
        try state.setHash("hash", for: "target-1")
        try state.setMetaValue("token-blob", forKey: RelayProcessor.relayTokenKey)
        try state.markRelayProcessed("action-1", at: Date())

        try state.wipeSyncState()

        XCTAssertTrue(try state.hashes(forKind: .target).isEmpty, "slice hashes cleared → next publish re-pushes")
        XCTAssertNil(try state.metaValue(forKey: RelayProcessor.relayTokenKey), "relay token cleared → relay re-read from scratch")
        XCTAssertFalse(try state.isRelayProcessed("action-1"), "processed set cleared")
    }

    func testPruneRelayProcessedRemovesOnlyOlderEntries() throws {
        let state = try HubSyncState.inMemory()
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 1_000_000)
        try state.markRelayProcessed("old", at: old)
        try state.markRelayProcessed("recent", at: recent)

        try state.pruneRelayProcessed(olderThan: Date(timeIntervalSince1970: 500_000))

        XCTAssertFalse(try state.isRelayProcessed("old"), "old processed entry pruned")
        XCTAssertTrue(try state.isRelayProcessed("recent"), "recent processed entry retained")
    }
}
