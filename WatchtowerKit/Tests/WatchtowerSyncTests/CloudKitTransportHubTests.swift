import CloudKit
import XCTest
@testable import WatchtowerSync

/// Multi-hub spec §4: a transport knows its hub, maps zone kinds to
/// `<Kind>Zone-<hubID>`, ignores every other hub, and only a hub writes zones.
final class CloudKitTransportHubTests: XCTestCase {
    private let owner = "_owner-acme"
    private var shared: CloudDatabaseScope { .shared(ownerName: owner) }

    private func record(_ name: String, zone: CloudZoneID = .relay) -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "action", modifiedAt: Date(), payload: Data("{}".utf8))
    }

    private func ckRecord(_ name: String, in zoneID: CKRecordZone.ID) -> CKRecord {
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        ck.encryptedValues["payload"] = Data("{}".utf8)
        ck["kind"] = "action"
        ck["modifiedAt"] = Date(timeIntervalSince1970: 1_700_000_000)
        return ck
    }

    private func savedZoneNames(_ engine: FakeSyncEngine) -> [String] {
        engine.databaseChanges.compactMap { if case .saveZone(let zone) = $0 { return zone.zoneID.zoneName } else { return nil } }
    }

    func testZoneNamesCarryTheHubID() {
        let zones = HubZones(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(zones.zoneID(for: .data).zoneName, "DataZone-hub-acme")
        XCTAssertEqual(zones.zoneID(for: .relay).zoneName, "RelayZone-hub-acme")
        XCTAssertEqual(zones.zoneID(for: .data).ownerName, CKCurrentUserDefaultName)
        XCTAssertEqual(HubZones(scope: shared, hubID: "hub-acme").zoneID(for: .relay).ownerName, owner)
        XCTAssertEqual(zones.allZoneIDs.map(\.zoneName), ["DataZone-hub-acme", "RelayZone-hub-acme"])
    }

    func testCloudZoneMatchesOnlyThisHubAndInSharedScopeThisOwner() {
        let zones = HubZones(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(zones.cloudZone(for: zones.zoneID(for: .relay)), .relay)
        XCTAssertNil(zones.cloudZone(for: HubZones(scope: .private, hubID: "hub-other").zoneID(for: .data)))
        XCTAssertNil(zones.cloudZone(for: CKRecordZone.ID(zoneName: "DataZone", ownerName: CKCurrentUserDefaultName)),
                     "the single-hub build's zone is not ours")
        XCTAssertNil(zones.cloudZone(for: CKRecordZone.ID(zoneName: "DataZone-hub-acme-x", ownerName: CKCurrentUserDefaultName)))
        let sharedZones = HubZones(scope: shared, hubID: "hub-acme")
        XCTAssertNil(sharedZones.cloudZone(for: CKRecordZone.ID(zoneName: "DataZone-hub-acme", ownerName: "_someone-else")))
        XCTAssertNil(sharedZones.cloudZone(for: HubZones(scope: shared, hubID: "hub-acme-2").zoneID(for: .data)),
                     "two hubs of one foreign owner never cross")
    }

    func testHubRoleStartRegistersItsOwnTwoZones() async throws {
        let engine = FakeSyncEngine()
        _ = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        XCTAssertEqual(savedZoneNames(engine), [HubZones.testDataZoneName, HubZones.testRelayZoneName])
    }

    func testPhoneRoleInPrivateScopeNeverWritesZonesAndUnlinksWhenItsHubsZonesGo() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), role: .phone, engine: engine)
        let events = Collector<TransportEvent>()
        await transport.setEventHandler { events.append($0) }

        await transport.handleDeletedZones([HubZones.test().zoneID(for: .data)])
        await transport.resetForAccountChange()
        await transport.restartTask?.value

        XCTAssertTrue(engine.databaseChanges.isEmpty, "a phone never creates or deletes a zone")
        XCTAssertEqual(events.values, [.unlinked])
    }

    func testFetchAndSendAreScopedToThisHubsZones() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        try await transport.save([record("action-1")])

        try await transport.pull()
        await transport.sendNow()

        let own = HubZones.test().allZoneIDs
        XCTAssertFalse(engine.fetchScopes.isEmpty)
        XCTAssertTrue(engine.fetchScopes.allSatisfy { $0 == own })
        XCTAssertEqual(engine.sendScopes, [own])
        XCTAssertEqual(Set(engine.zoneFetches.map(\.zoneID)), Set(own), "the poll reads only this hub's zones")
    }

    /// Review focus 1.
    func testRecordsAndDeletionsOfAnotherHubOrTheLegacyZoneAreIgnored() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)
        let events = Collector<TransportEvent>()
        await transport.setEventHandler { events.append($0) }
        let other = HubZones(scope: .private, hubID: "hub-other").zoneID(for: .relay)
        let legacy = CKRecordZone.ID(zoneName: "RelayZone", ownerName: CKCurrentUserDefaultName)
        let own = HubZones.test().zoneID(for: .relay)

        await transport.bufferFetched(
            modifications: [ckRecord("action-other", in: other), ckRecord("action-legacy", in: legacy), ckRecord("action-own", in: own)],
            deletions: [CKRecord.ID(recordName: "action-gone", zoneID: other)]
        )
        await transport.handleDeletedZones([other, legacy])
        await transport.handleSentChanges(
            saved: [ckRecord("action-x", in: other)], deleted: [], failedSaves: [], failedDeletes: [:]
        )

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["action-own"])
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
        XCTAssertNil(try store.systemFields(recordName: "action-other", zone: .relay))
        XCTAssertTrue(events.values.isEmpty)
    }

    /// Review focus 2: archived single-hub system fields carry the legacy
    /// zone in their record id; a store bound to no hub is wiped at start.
    func testAStoreBoundToNoHubIsWipedSoNoSaveTargetsTheLegacyZone() async throws {
        let store = try TransportStore.inMemory()
        let legacy = CKRecordZone.ID(zoneName: "RelayZone", ownerName: CKCurrentUserDefaultName)
        try store.saveSystemFields(CloudKitTransport.archivedSystemFields(of: ckRecord("action-1", in: legacy)),
                                   recordName: "action-1", zone: .relay)
        try store.enqueueSave([record("action-1")])

        let transport = await CloudKitTransport.testing(store: store)
        try await transport.save([record("action-1")])
        let batch = await transport.nextEngineBatch()

        XCTAssertEqual(batch?.recordsToSave.map(\.recordID.zoneID.zoneName), [HubZones.testRelayZoneName])
        XCTAssertEqual(try store.storedHubID(), HubZones.testHubID)
    }

    func testAStoreOfAnotherHubIsWipedAndOfTheSameHubKept() async throws {
        let store = try TransportStore.inMemory()
        try store.saveScope(.private, hubID: "hub-other")
        try store.saveEngineState(Data("other-engine".utf8))
        _ = await CloudKitTransport.testing(store: store)
        XCTAssertNil(try store.loadEngineState(), "another hub's engine state must not drive this hub")

        try store.saveEngineState(Data("own-engine".utf8))
        _ = await CloudKitTransport.testing(store: store)
        XCTAssertEqual(try store.loadEngineState(), Data("own-engine".utf8))
    }
}
