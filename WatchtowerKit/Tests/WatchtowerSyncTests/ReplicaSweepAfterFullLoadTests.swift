import GRDB
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// Board #1497 (M4 of relay client Phase 3a's final review): the route-change sweep runs after the transport's
/// full load, not on the first non-empty batch, so rows of pages not loaded yet are not deleted for a while.
final class ReplicaSweepAfterFullLoadTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// An in-memory transport that says whether its load is whole; the flag is the test's.
    private final class GatedTransport: CloudSyncTransport, InitialLoadReporting, @unchecked Sendable {
        let inner = InMemoryCloudTransport()
        var complete = false
        /// When set, the answers in turn (the last repeats) instead of `complete`.
        var answers: [Bool] = []
        func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws { try await inner.delete(recordNames: recordNames, in: zone) }
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            try await inner.changes(in: zone, since: token)
        }
        func dataLoadComplete() async -> Bool {
            if answers.count > 1 { return answers.removeFirst() }
            return answers.first ?? complete
        }
    }

    private func slice(_ id: String) -> CloudRecord {
        CloudRecordFactory.record(for: SliceRecord(kind: .briefing, id: id, modifiedAt: base, payload: Data("{}".utf8)))
    }

    private func names(_ store: ReplicaStore) async throws -> Set<String> {
        let rows = try await store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT COALESCE(plain_name, record_name) FROM slice_records")
        }
        let ids = rows.map { String($0.split(separator: "-").last ?? "") }
        return Set(ids).intersection(["kept", "far", "gone"])  // the keybox is not a subject here
    }

    private func assertNames(_ store: ReplicaStore, _ expected: Set<String>, _ message: String = "", line: UInt = #line) async throws {
        let actual = try await names(store)
        XCTAssertEqual(actual, expected, message, line: line)
    }

    /// Rows of the old route: kept, far, gone; the route then changes to the relay.
    private func routeChangedStore(_ keys: InMemoryPhoneKeyStore) async throws -> ReplicaStore {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let old = InMemoryCloudTransport()
        let oldHub = TestE2E.hubTransport(TestE2E.hub(), inner: old)
        try await oldHub.save([slice("kept"), slice("far"), slice("gone"), try TestE2E.keyboxRecord(modifiedAt: base)])
        let oldBatch = try await old.changes(in: .data, since: nil)
        XCTAssertTrue(try store.apply(oldBatch))
        _ = try store.indexPending()
        XCTAssertFalse(try store.adoptRoute("cloudkit"))
        XCTAssertTrue(try store.adoptRoute("relay"))
        return store
    }

    /// The new transport's first page holds "kept"; "far" arrives with a later page.
    func testAMultiPageLoadKeepsFarRowsUntilItFinishes() async throws {
        let keys = try TestE2E.phoneStore()
        let store = try await routeChangedStore(keys)
        let new = GatedTransport()
        let hub = TestE2E.hubTransport(TestE2E.hub(firstSeq: 1_000), inner: new)
        let hydrator = ReplicaHydrator(transport: new, store: store)

        try await hub.save([slice("kept")])
        try await hydrator.hydrateOnce()
        try await assertNames(store, ["kept", "far", "gone"], "the first page alone sweeps nothing")
        XCTAssertTrue(try store.sweepsAfterFullPull())
        XCTAssertNil(try store.storedToken(), "the token waits for the whole load")

        try await hub.save([slice("far")])
        try await hydrator.hydrateOnce()
        try await assertNames(store, ["kept", "far", "gone"], "still loading")

        new.complete = true
        try await hydrator.hydrateOnce()
        try await assertNames(store, ["kept", "far"], "rows truly gone are removed after the load")
        XCTAssertFalse(try store.sweepsAfterFullPull())
        XCTAssertNotNil(try store.storedToken())
    }

    /// The load fails midway: the cycles in between sweep nothing, and a later full load still sweeps. The same
    /// store state serves an app restart (the mark and the missing token are persisted, nothing else is kept).
    func testAFailedLoadSweepsNothingAndALaterFullLoadStillSweeps() async throws {
        let keys = try TestE2E.phoneStore()
        let store = try await routeChangedStore(keys)
        let new = GatedTransport()
        let hub = TestE2E.hubTransport(TestE2E.hub(firstSeq: 1_000), inner: new)
        try await hub.save([slice("kept")])

        // Several cycles over the same partial buffer (a restart re-reads it the same way).
        for _ in 0..<3 {
            try await ReplicaHydrator(transport: new, store: store).hydrateOnce()
            try await assertNames(store, ["kept", "far", "gone"])
            XCTAssertTrue(try store.sweepsAfterFullPull())
            XCTAssertNil(try store.storedToken())
        }

        try await hub.save([slice("far")])
        new.complete = true
        try await ReplicaHydrator(transport: new, store: store).hydrateOnce()
        try await assertNames(store, ["kept", "far"])
        XCTAssertFalse(try store.sweepsAfterFullPull())
    }

    /// A load that starts after the first answer (complete, then loading) is not a whole load.
    func testALoadStartingDuringTheReadIsNotComplete() async throws {
        let keys = try TestE2E.phoneStore()
        let store = try await routeChangedStore(keys)
        let new = GatedTransport()
        let hub = TestE2E.hubTransport(TestE2E.hub(firstSeq: 1_000), inner: new)
        try await hub.save([slice("kept")])
        new.answers = [true, false]
        try await ReplicaHydrator(transport: new, store: store).hydrateOnce()
        try await assertNames(store, ["kept", "far", "gone"])
        XCTAssertTrue(try store.sweepsAfterFullPull())
    }

    /// An empty buffer read (the first pull has not landed) must not spend the sweep.
    func testAnEmptyReadBeforeTheLoadDoesNotSpendTheSweep() async throws {
        let keys = try TestE2E.phoneStore()
        let store = try await routeChangedStore(keys)
        let new = GatedTransport()
        new.complete = true
        try await ReplicaHydrator(transport: new, store: store).hydrateOnce()
        XCTAssertNil(try store.storedToken())
        let hub = TestE2E.hubTransport(TestE2E.hub(firstSeq: 1_000), inner: new)
        try await hub.save([slice("kept")])
        try await ReplicaHydrator(transport: new, store: store).hydrateOnce()
        try await assertNames(store, ["kept"])
    }
}
