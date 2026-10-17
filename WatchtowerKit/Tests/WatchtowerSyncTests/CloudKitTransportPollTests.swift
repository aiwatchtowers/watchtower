import CloudKit
import XCTest
@testable import WatchtowerSync

/// `pull()` polls every zone of its scope straight from the server: the
/// CKSyncEngine fetches only the zones a delivered push named, so without
/// the poll a manual pull reaches nothing.
final class CloudKitTransportPollTests: XCTestCase {
    private let owner = "_acme-owner-record"
    private var shared: CloudDatabaseScope { .shared(ownerName: owner) }
    private var sharedZones: HubZones { .test(shared) }

    private func ckRecord(_ name: String, zone: CloudZoneID, scope: CloudDatabaseScope = .private) -> CKRecord {
        CloudKitTransport.ckRecord(
            from: CloudRecord(recordName: name, zone: zone, kind: "action", modifiedAt: Date(), payload: Data("{}".utf8)),
            in: HubZones.test(scope).zoneID(for: zone),
            systemFields: nil
        )
    }

    private func page(
        _ records: [CKRecord] = [],
        deletions: [CKRecord.ID] = [],
        token: String,
        moreComing: Bool = false
    ) -> Result<PolledZoneChanges, Error> {
        .success(PolledZoneChanges(
            modifications: records, deletions: deletions, changeToken: Data(token.utf8), moreComing: moreComing
        ))
    }

    func testPullPollsEveryZoneOfThePrivateScope() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)

        try await transport.pull()

        XCTAssertEqual(engine.fetchCount, 1, "the engine still fetches what it knows about")
        XCTAssertEqual(engine.zoneFetches, CloudZoneID.allCases.map {
            FakeSyncEngine.ZoneFetch(zoneID: HubZones.test().zoneID(for: $0), token: nil)
        })
    }

    func testPullPollsTheOwnersSharedZones() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)

        try await transport.pull()

        XCTAssertEqual(engine.zoneFetches.map(\.zoneID), CloudZoneID.allCases.map { sharedZones.zoneID(for: $0) })
        XCTAssertTrue(engine.zoneFetches.allSatisfy { $0.zoneID.ownerName == owner })
    }

    func testTheNextPullResumesFromTheStoredTokens() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: store, engine: engine)

        try await transport.pull()
        try await transport.pull()

        let second = engine.zoneFetches.suffix(2)
        XCTAssertEqual(second.map(\.token), [Data("\(HubZones.testDataZoneName)-1".utf8), Data("\(HubZones.testRelayZoneName)-1".utf8)])
        XCTAssertEqual(try store.pollToken(zone: .relay), Data("\(HubZones.testRelayZoneName)-2".utf8))
    }

    func testPolledRecordsAreBufferedForConsumers() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(page([ckRecord("device-1", zone: .relay)], token: "r1", moreComing: true), zoneName: HubZones.testRelayZoneName)
        engine.enqueueZonePage(page([ckRecord("action-2", zone: .relay)], token: "r2"), zoneName: HubZones.testRelayZoneName)
        let transport = await CloudKitTransport.testing(store: store, engine: engine)

        try await transport.pull()

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["device-1", "action-2"])
        XCTAssertEqual(engine.zoneFetches.filter { $0.zoneID.zoneName == HubZones.testRelayZoneName }.map(\.token), [nil, Data("r1".utf8)],
                       "a page with more coming is followed at once")
        XCTAssertEqual(try store.pollToken(zone: .relay), Data("r2".utf8))
        XCTAssertNotNil(try store.systemFields(recordName: "device-1", zone: .relay))
    }

    func testPolledDeletionIsBufferedOnlyForAKnownRecord() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: store, engine: engine)
        _ = await transport.bufferFetched(modifications: [ckRecord("known", zone: .relay)], deletions: [])
        let relay = HubZones.test().zoneID(for: .relay)
        engine.enqueueZonePage(page(deletions: [
            CKRecord.ID(recordName: "known", zoneID: relay),
            CKRecord.ID(recordName: "never-seen", zoneID: relay)
        ], token: "r1"), zoneName: HubZones.testRelayZoneName)

        try await transport.pull()

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.deletedRecordNames, ["known"])
    }

    func testExpiredPollTokenRestartsTheZoneFromTheBeginning() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: store, engine: engine)
        try await transport.pull()
        engine.enqueueZonePage(.failure(CKError(.changeTokenExpired)), zoneName: HubZones.testRelayZoneName)

        try await transport.pull()
        XCTAssertNil(try store.pollToken(zone: .relay))
        try await transport.pull()

        XCTAssertEqual(engine.zoneFetches.last, FakeSyncEngine.ZoneFetch(
            zoneID: HubZones.test().zoneID(for: .relay), token: nil
        ))
    }

    func testPrivateScopeMissingZoneOnThePollIsQuiet() async throws {
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(.failure(CKError(.zoneNotFound)), zoneName: HubZones.testDataZoneName)
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)

        try await transport.pull()

        XCTAssertEqual(engine.zoneFetches.map(\.zoneID.zoneName), [HubZones.testDataZoneName, HubZones.testRelayZoneName],
                       "a zone the engine has not created yet does not stop the other zone's poll")
    }

    func testSharedScopeMissingZoneOnThePollUnlinks() async throws {
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(.failure(CKError(.zoneNotFound)), zoneName: HubZones.testDataZoneName)
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = Collector<TransportEvent>()
        await transport.setEventHandler { collected.append($0) }

        try await transport.pull()
        try await transport.pull()

        XCTAssertEqual(collected.values, [.unlinked])
        XCTAssertEqual(engine.zoneFetches.count, 1, "nothing is polled once unlinked")
    }

    func testThrottledPollSkipsPullsUntilTheWaitEnds() async throws {
        let clock = TestClock()
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(
            .failure(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])), zoneName: HubZones.testDataZoneName
        )
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine, clock: clock) {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
        addTeardownBlock { await transport.retryTask?.cancel() }

        try await transport.pull()
        XCTAssertEqual(engine.zoneFetches.count, 1, "the throttle stops the poll at once")
        try await transport.pull()
        XCTAssertEqual(engine.fetchCount, 1, "no fetch while throttled")

        clock.advance(31)
        try await transport.pull()
        XCTAssertEqual(engine.fetchCount, 2)
        XCTAssertEqual(engine.zoneFetches.count, 3)
    }

    func testOtherPollErrorsAreThrown() async throws {
        let engine = FakeSyncEngine()
        engine.enqueueZonePage(.failure(CKError(.serverRejectedRequest)), zoneName: HubZones.testDataZoneName)
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)

        do {
            try await transport.pull()
            XCTFail("an unhandled poll error must surface")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .serverRejectedRequest)
        }
    }

    func testAFailedEngineFetchSkipsThePoll() async throws {
        let engine = FakeSyncEngine(fetchErrors: [CKError(.serverRejectedRequest)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)

        _ = try? await transport.pull()

        XCTAssertTrue(engine.zoneFetches.isEmpty)
    }

    func testAStoppedTransportDoesNotPoll() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        await transport.stop()

        try await transport.pull()

        XCTAssertTrue(engine.zoneFetches.isEmpty)
    }

    func testWipeAndZoneEvictionForgetPollTokens() throws {
        let store = try TransportStore.inMemory()
        try store.setPollToken(Data("d".utf8), zone: .data)
        try store.setPollToken(Data("r".utf8), zone: .relay)

        try store.evictZone(.relay)
        XCTAssertNil(try store.pollToken(zone: .relay))
        XCTAssertEqual(try store.pollToken(zone: .data), Data("d".utf8))

        try store.wipe()
        XCTAssertNil(try store.pollToken(zone: .data))
    }
}
