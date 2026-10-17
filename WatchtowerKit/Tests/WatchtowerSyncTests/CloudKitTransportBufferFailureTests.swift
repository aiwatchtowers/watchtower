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

    private func page(_ records: [CKRecord], token: String) -> Result<PolledZoneChanges, Error> {
        .success(PolledZoneChanges(modifications: records, deletions: [], changeToken: Data(token.utf8), moreComing: false))
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

        try store.failInserts(true)
        await transport.bufferEngineFetched(modifications: [ckRecord("lost-1", zone: .relay)], deletions: [])
        await transport.saveEngineState(Data("past-lost-1".utf8))

        XCTAssertEqual(try store.loadEngineState(), Data("before".utf8), "the token must not move past an unbuffered batch")
        let failure = await transport.lastError
        XCTAssertNotNil(failure)

        try store.failInserts(false)
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

    func testAFailedSystemFieldsWriteBuffersNothingOfTheBatch() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)

        try store.failInserts(into: "system_fields", true)
        let buffered = await transport.bufferFetched(
            modifications: [ckRecord("action-1", zone: .relay), ckRecord("action-2", zone: .relay)], deletions: []
        )

        XCTAssertFalse(buffered)
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty, "a failed batch leaves no events behind to duplicate on the retry")
        XCTAssertNil(try store.systemFields(recordName: "action-1", zone: .relay))
    }

    func testAFailedPollPageKeepsThatZonesTokenAndPollsTheOthers() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(page([ckRecord("target-1", zone: .data)], token: "d1"), zoneName: HubZones.testDataZoneName)
        engine.enqueueZonePage(page([], token: "r1"), zoneName: HubZones.testRelayZoneName)
        let transport = await CloudKitTransport.testing(store: store, engine: engine)

        try store.failInserts(true)
        try await transport.pull()

        XCTAssertNil(try store.pollToken(zone: .data), "an unbuffered page keeps the old token")
        XCTAssertEqual(try store.pollToken(zone: .relay), Data("r1".utf8), "the other zone is still polled")

        try store.failInserts(false)
        engine.enqueueZonePage(page([ckRecord("target-1", zone: .data)], token: "d1"), zoneName: HubZones.testDataZoneName)
        try await transport.pull()

        let dataFetches = engine.zoneFetches.filter { $0.zoneID.zoneName == HubZones.testDataZoneName }
        XCTAssertEqual(dataFetches.map(\.token), [nil, nil], "the next pull reads the page again")
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(try store.pollToken(zone: .data), Data("d1".utf8))
    }

    func testAFullPollAfterAFailedEngineBatchRecoversItAndResumesSavingState() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: store, engine: engine)
        await transport.saveEngineState(Data("before".utf8))

        try store.failInserts(true)
        await transport.bufferEngineFetched(modifications: [ckRecord("lost-1", zone: .relay)], deletions: [])
        engine.enqueueZonePage(page([ckRecord("lost-1", zone: .relay)], token: "r1"), zoneName: HubZones.testRelayZoneName)
        try await transport.pull()
        await transport.saveEngineState(Data("during-failure".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("before".utf8), "a poll that could not buffer keeps the state frozen")

        try store.failInserts(false)
        engine.enqueueZonePage(page([ckRecord("lost-1", zone: .relay)], token: "r1"), zoneName: HubZones.testRelayZoneName)
        try await transport.pull()

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["lost-1"], "the poll brings the lost record in")
        await transport.saveEngineState(Data("after-poll".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("after-poll".utf8), "engine state saving resumes")
    }

    func testEventsOfAStoppedEngineAreDropped() async throws {
        let transport = await CloudKitTransport.testing(store: try .inMemory())
        let firstBox = await transport.delegateBox
        let oldBox = try XCTUnwrap(firstBox)
        let oldIsCurrent = await transport.isCurrentEngine(oldBox)
        XCTAssertTrue(oldIsCurrent)

        await transport.stop()
        let stoppedIsCurrent = await transport.isCurrentEngine(oldBox)
        XCTAssertFalse(stoppedIsCurrent)

        await transport.start()
        let secondBox = await transport.delegateBox
        let newBox = try XCTUnwrap(secondBox)
        let staleIsCurrent = await transport.isCurrentEngine(oldBox)
        let newIsCurrent = await transport.isCurrentEngine(newBox)
        XCTAssertFalse(staleIsCurrent, "a replaced engine's events are not this engine's")
        XCTAssertTrue(newIsCurrent)
    }
}
