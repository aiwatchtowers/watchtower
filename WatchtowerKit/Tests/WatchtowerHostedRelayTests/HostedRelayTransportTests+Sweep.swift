import Foundation
import GRDB
import os
@testable import WatchtowerHostedRelay
import WatchtowerE2ETesting
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Board #1497: the replica's route-change sweep waits for the hosted transport's full data load. The real
/// transport, the real hydrator and a real replica together: a failed page and a restart midway sweep nothing.
extension HostedRelayTransportTests {
    private var sweepStamp: Date { Self.stamp }

    private func sliceRecord(_ id: String) -> CloudRecord {
        CloudRecordFactory.record(for: SliceRecord(kind: .briefing, id: id, modifiedAt: sweepStamp, payload: Data("{}".utf8)))
    }

    /// The Mac writes these slices sealed (the hub's envelopes, as the replica opens them) into the relay data zone.
    private func macSaveSealed(_ mac: HostedRelayClient, _ zone: String, _ ids: [String], hub: TestHubKeyProvider) async throws {
        let inner = InMemoryCloudTransport()
        let sealing = TestE2E.hubTransport(hub, inner: inner)
        try await sealing.save(ids.map(sliceRecord))
        for record in try await inner.changes(in: .data, since: nil).changed {
            var item = Relay_V1_SaveItem()
            item.record.zone = zone
            item.record.name = record.recordName
            item.record.envelope = record.payload
            item.record.clientModifiedAtMs = Self.stampMs
            var save = Relay_V1_Save()
            save.items = [item]
            guard try await mac.save(save).saved.first != nil else { throw ScenarioFailure.unexpected("save \(record.recordName)") }
        }
    }

    private func replicaIDs(_ store: ReplicaStore) async throws -> Set<String> {
        _ = try store.indexPending()
        let rows = try await store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT COALESCE(plain_name, record_name) FROM slice_records")
        }
        return Set(rows.map { String($0.split(separator: "-").last ?? "") }).intersection(["kept", "mid", "far", "gone"])
    }

    /// A replica with rows `kept`, `far`, `gone` from the old route, its route moved to the relay.
    private func routeChangedReplica(_ keys: InMemoryPhoneKeyStore) async throws -> ReplicaStore {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let old = InMemoryCloudTransport()
        try await TestE2E.hubTransport(TestE2E.hub(), inner: old).save(["kept", "far", "gone"].map(sliceRecord))
        let oldBatch = try await old.changes(in: .data, since: nil)
        XCTAssertTrue(try store.apply(oldBatch))
        XCTAssertFalse(try store.adoptRoute("cloudkit"))
        XCTAssertTrue(try store.adoptRoute("relay"))
        return store
    }

    /// The pull's failure is swallowed, as the engine-fetched handler reads the buffer after a failed page.
    private func swallowingHydrator(_ transport: HostedRelayTransport, _ replica: ReplicaStore) -> ReplicaHydrator {
        let pull: @Sendable () async throws -> Void = { try? await transport.pull() }
        return ReplicaHydrator(transport: transport, store: replica, pull: pull)
    }

    private func pageOneBytes() throws {
        var limits = try relay.limits
        limits.changesPageBytes = 1
        try relay.limits = limits
    }

    /// The hydrator reads whatever the buffer holds after a pull, as the engine-fetched handler does after a failed
    /// page (`pull` swallows the failure): a failed page 2 and an app restart sweep nothing; the full load sweeps.
    func testARouteChangeSweepsOnlyAfterTheHostedLoadIsWhole() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let zone = dataZone(mac)
        let hubKeys = TestE2E.hub(firstSeq: 1_000)
        try await macSaveSealed(mac, zone, ["kept", "mid", "far"], hub: hubKeys)
        try pageOneBytes()
        let keys = try TestE2E.phoneStore()
        let replica = try await routeChangedReplica(keys)
        let path = try storePath()
        var store = try TransportStore(path: path)
        var (transport, _) = try await makeTransport(phone, mac: mac, store: store)

        intercepting.answer { request in
            if case .changes(let changes) = request.op, changes.zone == zone, changes.sinceSeq == 1 {
                throw URLError(.networkConnectionLost)
            }
            return nil
        }
        var hydrator = swallowingHydrator(transport, replica)
        try await hydrator.hydrateOnce()
        var ids = try await replicaIDs(replica)
        XCTAssertEqual(ids, ["kept", "far", "gone"], "page 1 of 3 is in; nothing is swept")
        XCTAssertTrue(try replica.sweepsAfterFullPull())

        // The app restarts mid-load: a new transport on the same store file, a new hydrator.
        await transport.stop()
        try store.close()
        store = try TransportStore(path: path)
        (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        hydrator = swallowingHydrator(transport, replica)
        try await hydrator.hydrateOnce()
        ids = try await replicaIDs(replica)
        XCTAssertEqual(ids, ["kept", "far", "gone"], "still failing after the restart")

        intercepting.answer(nil)
        try await hydrator.hydrateOnce()
        ids = try await replicaIDs(replica)
        XCTAssertEqual(ids, ["kept", "mid", "far"], "the full load sweeps what it did not return")
        XCTAssertFalse(try replica.sweepsAfterFullPull())
    }

    /// A route return onto a transport store whose cursor is above 0 loads again from 0 (the session asks), and a
    /// failed page 2 plus a restart sweep nothing until the whole load is in.
    func testARouteReturnWithACursorAboveZeroReportsItsLoad() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let zone = dataZone(mac)
        let hubKeys = TestE2E.hub(firstSeq: 1_000)
        try await macSaveSealed(mac, zone, ["kept", "mid", "far"], hub: hubKeys)
        try pageOneBytes()
        let path = try storePath()
        var store = try TransportStore(path: path)
        var (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.pull()  // an earlier stay on this route: the cursor is above 0
        XCTAssertGreaterThan(try store.relayCursor(zone: .data), 0)
        let completeBefore = await transport.dataLoadComplete()
        XCTAssertTrue(completeBefore)

        let keys = try TestE2E.phoneStore()
        let replica = try await routeChangedReplica(keys)
        try transport.restartDataLoadIfIdle()
        let loading = await transport.dataLoadComplete()
        XCTAssertFalse(loading, "the buffer's leftover events are not a load")

        intercepting.answer { request in
            if case .changes(let changes) = request.op, changes.zone == zone, changes.sinceSeq == 1 {
                throw URLError(.networkConnectionLost)
            }
            return nil
        }
        var hydrator = swallowingHydrator(transport, replica)
        try await hydrator.hydrateOnce()
        var ids = try await replicaIDs(replica)
        XCTAssertTrue(ids.isSuperset(of: ["kept", "far", "gone"]), "the leftover events apply, nothing is swept: \(ids)")

        await transport.stop()
        try store.close()
        store = try TransportStore(path: path)
        (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try transport.restartDataLoadIfIdle()  // a running load is resumed, not started again
        XCTAssertTrue(try store.relayResyncPending(.data))
        XCTAssertGreaterThan(try store.relayCursor(zone: .data), 0)
        hydrator = swallowingHydrator(transport, replica)
        try await hydrator.hydrateOnce()
        ids = try await replicaIDs(replica)
        XCTAssertTrue(ids.isSuperset(of: ["kept", "far", "gone"]), "the leftover events apply, nothing is swept: \(ids)")

        intercepting.answer(nil)
        try await hydrator.hydrateOnce()
        ids = try await replicaIDs(replica)
        XCTAssertEqual(ids, ["kept", "mid", "far"])
        XCTAssertFalse(try replica.sweepsAfterFullPull())
    }

    /// A first pull whose middle page expires restarts from 0 at once; only a real resync stalls.
    func testAFirstPullRestartsAtOnceWhenAMiddlePageExpires() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let zone = dataZone(mac)
        for name in ["a", "b", "c"] { try await macSave(mac, zone, name) }
        try pageOneBytes()
        let refusals = OSAllocatedUnfairLock(initialState: 0)
        intercepting.answer { request in
            guard case .changes(let changes) = request.op, changes.zone == zone, changes.sinceSeq == 1 else { return nil }
            let first = refusals.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            guard first else { return nil }
            var refused = Relay_V1_Error()
            refused.code = .tokenExpired
            var response = Relay_V1_Response()
            response.error = refused
            return response
        }
        let store = try TransportStore.inMemory()
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.pull()
        XCTAssertFalse(try store.relayResyncStalled(.data), "not held for an hour")
        XCTAssertFalse(try store.relayResyncPending(.data))
        XCTAssertEqual(try changesSinces(zone), [0, 0, 1, 2], "page 2 refused (not logged), restarted from 0 at once")
        XCTAssertEqual(refusals.withLock { $0 }, 2, "refused once, then served")
        XCTAssertEqual(try buffered(store, .data).changed.map(\.recordName).sorted(), ["a", "b", "c"])
    }
}
