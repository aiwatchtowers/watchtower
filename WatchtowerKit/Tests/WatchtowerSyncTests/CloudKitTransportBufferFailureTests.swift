import CloudKit
import XCTest
@testable import WatchtowerSync

/// A fetched batch that fails to reach the local buffer must not have its
/// change token saved past it: the batch is fetched again instead of lost.
final class CloudKitTransportBufferFailureTests: XCTestCase {
    private func ckRecord(_ name: String, zone: CloudZoneID) -> CKRecord {
        CloudKitTransport.ckRecord(
            from: CloudRecord(recordName: name, zone: zone, kind: "action", modifiedAt: Date(), payload: Data("{}".utf8)),
            in: HubZones.test().zoneID(for: zone),
            systemFields: nil
        )
    }

    func testEngineStateIsSavedAfterABufferedBatch() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)

        await transport.bufferEngineFetched(modifications: [ckRecord("a-1", zone: .relay)], deletions: [])
        await transport.saveEngineState(Data("after-a-1".utf8))

        XCTAssertEqual(try store.loadEngineState(), Data("after-a-1".utf8))
    }

    func testAFailedEngineBatchKeepsTheEngineStateUntilTheNextStart() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)
        await transport.saveEngineState(Data("before".utf8))

        try store.failBufferWrites(true)
        await transport.bufferEngineFetched(modifications: [ckRecord("lost-1", zone: .relay)], deletions: [])
        await transport.saveEngineState(Data("past-lost-1".utf8))

        XCTAssertEqual(try store.loadEngineState(), Data("before".utf8), "the token must not move past an unbuffered batch")
        let failure = await transport.lastError
        XCTAssertNotNil(failure)

        try store.failBufferWrites(false)
        await transport.bufferEngineFetched(modifications: [ckRecord("next-2", zone: .relay)], deletions: [])
        await transport.saveEngineState(Data("past-next-2".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("before".utf8),
                       "a later good batch does not save a state that is past the lost one")

        await transport.stop()
        await transport.start()
        await transport.saveEngineState(Data("restarted".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("restarted".utf8),
                       "the next engine resumes from the stored state and saves again")
    }

    func testAFailedPollPageKeepsThePollToken() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(.success(PolledZoneChanges(
            modifications: [ckRecord("action-1", zone: .relay)], deletions: [], changeToken: Data("r1".utf8), moreComing: false
        )), zoneName: HubZones.testRelayZoneName)
        let transport = await CloudKitTransport.testing(store: store, engine: engine)

        try store.failBufferWrites(true)
        try await transport.pull()
        XCTAssertNil(try store.pollToken(zone: .relay), "an unbuffered page keeps the old token")

        try store.failBufferWrites(false)
        engine.enqueueZonePage(.success(PolledZoneChanges(
            modifications: [ckRecord("action-1", zone: .relay)], deletions: [], changeToken: Data("r1".utf8), moreComing: false
        )), zoneName: HubZones.testRelayZoneName)
        try await transport.pull()

        let relayFetches = engine.zoneFetches.filter { $0.zoneID.zoneName == HubZones.testRelayZoneName }
        XCTAssertEqual(relayFetches.map(\.token), [nil, nil], "the next pull reads the page again")
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["action-1"])
        XCTAssertEqual(try store.pollToken(zone: .relay), Data("r1".utf8))
    }
}
