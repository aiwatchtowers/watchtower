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
        let ck = CKRecord(recordType: "WatchtowerEnvelope", recordID: id)
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

    /// Final review M1: the delete lives on the transport, so a `start()`
    /// from any owner while it runs waits for it; its wipe never lands under
    /// a running engine.
    func testStartDuringAHubZoneDeleteWaitsForItsWipe() async throws {
        let entered = Gate()
        let release = Gate()
        let store = try TransportStore.inMemory()
        let admin = FakeZoneAdmin(zones: HubZones.test().allZoneIDs) {
            await entered.open()
            await release.wait()
        }
        let pendingAtBuild = Collector<Int>()
        let transport = CloudKitTransport(
            store: store, scope: .private, hubID: HubZones.testHubID, role: .hub, entitlementPresent: { true },
            zoneAdmin: admin,
            engineFactory: { _, _ in
                pendingAtBuild.append((try? store.pendingBatch(limit: 10).saves.count) ?? -1)
                return FakeSyncEngine()
            },
            now: { Date() }, sleep: { _ in }
        )
        await transport.start()
        try await transport.save([CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat", modifiedAt: Date(), payload: Data("{}".utf8))])
        await transport.stop()

        let delete = Task { try await transport.deleteHubZones() }
        await entered.wait()
        let start = Task { await transport.start() }
        while await transport.isStopped { await Task.yield() }
        XCTAssertEqual(pendingAtBuild.values.count, 1, "no engine is built while the delete runs")

        await release.open()
        try await delete.value
        await start.value

        XCTAssertEqual(pendingAtBuild.values, [0, 0], "the second engine is built on the wiped store")
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty)
    }

    func testADeleteWhileOneRunsJoinsIt() async throws {
        let entered = Gate()
        let release = Gate()
        let admin = FakeZoneAdmin(zones: HubZones.test().allZoneIDs) {
            await entered.open()
            await release.wait()
        }
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        await transport.stop()

        let first = Task { try await transport.deleteHubZones() }
        await entered.wait()
        let second = Task { try await transport.deleteHubZones() }
        await release.open()
        try await first.value
        try await second.value

        XCTAssertEqual(admin.deleted.count, 1, "one server delete")
    }

    /// Final review m1: a delete that removed something but did not finish
    /// is told apart from one that removed nothing.
    func testAPartialZoneDeleteIsPartlyDeletedAndAFailedOneIsCloudKitsError() async throws {
        let store = try TransportStore.inMemory()
        let partial = FakeZoneAdmin(deleteFailure: PartialZoneDeleteError(underlying: CKError(.networkFailure)))
        let first = await CloudKitTransport.testing(store: store, zoneAdmin: partial)
        try await first.save([CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat", modifiedAt: Date(), payload: Data("{}".utf8))])
        await first.stop()
        do { try await first.deleteHubZones(); XCTFail("partial") } catch HubZoneError.partlyDeleted {}
        XCTAssertFalse(try store.pendingBatch(limit: 10).saves.isEmpty, "the store is not wiped")

        let failed = FakeZoneAdmin(deleteFailure: CKError(.networkFailure))
        let second = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: failed)
        await second.stop()
        do {
            try await second.deleteHubZones()
            XCTFail("failed")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .networkFailure)
        }
    }

    func testDeleteResultsTellPartialFromNothingDeleted() throws {
        let gone: Result<Void, any Error> = .failure(CKError(.zoneNotFound))
        let failed: Result<Void, any Error> = .failure(CKError(.networkFailure))
        XCTAssertNoThrow(try CKDatabaseZoneAdmin.checkDeleteResults([.success(()), gone]))
        XCTAssertThrowsError(try CKDatabaseZoneAdmin.checkDeleteResults([.success(()), failed])) {
            XCTAssertTrue($0 is PartialZoneDeleteError)
        }
        XCTAssertThrowsError(try CKDatabaseZoneAdmin.checkDeleteResults([gone, failed])) {
            XCTAssertTrue($0 is PartialZoneDeleteError, "a zone already gone counts as deleted")
        }
        XCTAssertThrowsError(try CKDatabaseZoneAdmin.checkDeleteResults([failed, failed])) {
            XCTAssertEqual(($0 as? CKError)?.code, .networkFailure)
        }
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
        let bare = CKRecord(recordType: "WatchtowerEnvelope", recordID: id)
        let admin = FakeZoneAdmin(zones: [legacyData, legacyRelay], records: [bare])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        let outcome = try await transport.removeLegacyZones { _ in true }
        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(admin.deleted.isEmpty)
    }

    /// Final review m6: a lone legacy RelayZone has no heartbeat, so
    /// `deleteIf(nil)` decides.
    func testALoneLegacyRelayZoneIsDecidedByDeleteIfNil() async throws {
        let asked = Collector<Data?>()
        let keep = FakeZoneAdmin(zones: [legacyRelay])
        let first = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: keep)
        let kept = try await first.removeLegacyZones { asked.append($0); return false }
        XCTAssertEqual(kept, .kept)
        XCTAssertTrue(keep.deleted.isEmpty)
        XCTAssertEqual(asked.values.count, 1)
        XCTAssertNil(try XCTUnwrap(asked.values.first), "no legacy DataZone: no heartbeat")

        let drop = FakeZoneAdmin(zones: [legacyRelay])
        let second = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: drop)
        let deleted = try await second.removeLegacyZones { _ in true }
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(drop.deleted, [[legacyRelay]])
    }

    func testAFailedLegacyDeleteThrowsAndIsRetriedLater() async throws {
        let admin = FakeZoneAdmin(zones: [legacyData, legacyRelay], deleteFailure: CKError(.networkFailure))
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        do { _ = try await transport.removeLegacyZones(deleteIf: isOwn); XCTFail("throws") } catch let error as CKError {
            XCTAssertEqual(error.code, .networkFailure)
        }
        XCTAssertTrue(admin.deleted.isEmpty, "nothing is reported deleted")

        admin.setDeleteFailure(nil)
        let retried = try await transport.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(retried, .deleted)
        XCTAssertEqual(admin.deleted, [[legacyData, legacyRelay]])
    }

    func testLegacyCleanupIsRefusedForAPhoneAndWithoutTheEntitlement() async throws {
        let admin = FakeZoneAdmin(zones: [legacyData, legacyRelay])
        let phone = await CloudKitTransport.testing(store: try .inMemory(), role: .phone, zoneAdmin: admin)
        do { _ = try await phone.removeLegacyZones { _ in true }; XCTFail("not a hub") } catch HubZoneError.notHub {}

        let unentitled = CloudKitTransport(
            store: try .inMemory(), scope: .private, hubID: HubZones.testHubID, role: .hub, entitlementPresent: { false },
            zoneAdmin: admin, engineFactory: { _, _ in FakeSyncEngine() }, now: { Date() }, sleep: { _ in }
        )
        do { _ = try await unentitled.removeLegacyZones { _ in true }; XCTFail("no entitlement") } catch HubZoneError.noEntitlement {}
        XCTAssertTrue(admin.deleted.isEmpty)
    }
}
