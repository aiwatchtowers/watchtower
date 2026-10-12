import CloudKit
import XCTest
@testable import WatchtowerSync

/// Multi-hub spec §3.3 and §3.6: the hub deletes its own two zones when
/// turned off, and the single-hub build's zones only when they are its own.
final class CloudKitTransportZoneAdminTests: XCTestCase {
    private let legacyData = CKRecordZone.ID(zoneName: "DataZone", ownerName: CKCurrentUserDefaultName)
    private let legacyRelay = CKRecordZone.ID(zoneName: "RelayZone", ownerName: CKCurrentUserDefaultName)

    private func heartbeatRecord(hubID: String) throws -> CKRecord {
        let id = CKRecord.ID(recordName: HeartbeatPayload.recordName, zoneID: legacyData)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: id)
        var heartbeat = HeartbeatFixtures.minimal(updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        heartbeat = HeartbeatPayload(
            updatedAt: heartbeat.updatedAt, appVersion: heartbeat.appVersion, hubID: hubID, macName: heartbeat.macName,
            flavor: heartbeat.flavor, lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [],
            enabledAt: heartbeat.enabledAt, ownerUser: heartbeat.ownerUser, sharing: .none
        )
        ck.encryptedValues["payload"] = try RelayCoder.makeEncoder().encode(heartbeat)
        return ck
    }

    private func isOwn(_ payload: Data?) -> Bool {
        guard let payload else { return true }
        return (try? RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: payload))?.hubID == "hub-own"
    }

    func testDeleteHubZonesDeletesOnlyThisHubsTwoZonesAndWipesTheStore() async throws {
        let store = try TransportStore.inMemory()
        let admin = FakeZoneAdmin(zones: HubZones.test().allZoneIDs + [legacyData])
        let transport = await CloudKitTransport.testing(store: store, zoneAdmin: admin)
        try await transport.save([CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat", modifiedAt: Date(), payload: Data("{}".utf8))])
        await transport.stop()

        try await transport.deleteHubZones()

        XCTAssertEqual(admin.deleted, [HubZones.test().allZoneIDs])
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty, "the deleted zones' queue and state are gone")
    }

    func testDeleteHubZonesIsRefusedForAPhoneAndWhileTheEngineRuns() async throws {
        let phone = await CloudKitTransport.testing(store: try .inMemory(), role: .phone)
        await phone.stop()
        do { try await phone.deleteHubZones(); XCTFail("a phone never deletes zones") } catch HubZoneError.notHub {}

        let hub = await CloudKitTransport.testing(store: try .inMemory())
        do { try await hub.deleteHubZones(); XCTFail("stop first") } catch HubZoneError.engineRunning {}
    }

    func testNoLegacyZonesIsNoneFound() async throws {
        let admin = FakeZoneAdmin(zones: HubZones.test().allZoneIDs)
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        let outcome = try await transport.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(outcome, .noneFound)
        XCTAssertTrue(admin.deleted.isEmpty)
    }

    func testLegacyZonesWithOwnOrNoHeartbeatAreDeleted() async throws {
        let own = FakeZoneAdmin(zones: [legacyData, legacyRelay], records: [try heartbeatRecord(hubID: "hub-own")])
        let first = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: own)
        let deletedOwn = try await first.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(deletedOwn, .deleted)
        XCTAssertEqual(own.deleted, [[legacyData, legacyRelay]])

        let empty = FakeZoneAdmin(zones: [legacyRelay])
        let second = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: empty)
        let deletedEmpty = try await second.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(deletedEmpty, .deleted, "no heartbeat: nobody else's")
    }

    /// Review focus 4.
    func testLegacyZonesWithAnotherHubsHeartbeatAreKept() async throws {
        let admin = FakeZoneAdmin(zones: [legacyData, legacyRelay], records: [try heartbeatRecord(hubID: "hub-other")])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        let outcome = try await transport.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(admin.deleted.isEmpty)
    }

    /// Spec §3.6: a heartbeat it cannot read keeps the zones.
    func testLegacyZonesWithAnUnreadableHeartbeatAreKept() async throws {
        let id = CKRecord.ID(recordName: HeartbeatPayload.recordName, zoneID: legacyData)
        let bare = CKRecord(recordType: "WatchtowerRecord", recordID: id)
        let admin = FakeZoneAdmin(zones: [legacyData, legacyRelay], records: [bare])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        let outcome = try await transport.removeLegacyZones { _ in true }
        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(admin.deleted.isEmpty)
    }
}
