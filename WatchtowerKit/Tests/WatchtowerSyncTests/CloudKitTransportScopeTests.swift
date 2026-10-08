import CloudKit
import XCTest
@testable import WatchtowerSync

/// Database scopes (spec §2.3): a `shared` participant never writes zones,
/// and a vanished share moves it to "unlinked" (§9).
final class CloudKitTransportScopeTests: XCTestCase {
    private let owner = "_acme-owner-record"
    private var shared: CloudDatabaseScope { .shared(ownerName: owner) }

    private func record(_ name: String, zone: CloudZoneID = .relay) -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "action", modifiedAt: Date(), payload: Data("{}".utf8))
    }

    private func events(of transport: CloudKitTransport) async -> Collector<TransportEvent> {
        let collector = Collector<TransportEvent>()
        await transport.setEventHandler { collector.append($0) }
        return collector
    }

    // MARK: - Scope basics

    func testScopeDatabaseAndZoneOwner() {
        XCTAssertEqual(CloudDatabaseScope.private.zoneID(for: .data).ownerName, CKCurrentUserDefaultName)
        XCTAssertEqual(shared.zoneID(for: .relay).ownerName, owner)
        XCTAssertEqual(shared.zoneID(for: .relay).zoneName, "RelayZone")
        XCTAssertTrue(CloudDatabaseScope.private.writesZones)
        XCTAssertFalse(shared.writesZones)
    }

    func testPrivateScopeStartRegistersBothZones() async throws {
        let engine = FakeSyncEngine()
        _ = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        let saved = engine.databaseChanges.compactMap { change -> String? in
            if case .saveZone(let zone) = change { return zone.zoneID.zoneName }
            return nil
        }
        XCTAssertEqual(saved, ["DataZone", "RelayZone"])
    }

    // MARK: - Shared scope, no zone writes

    func testSharedScopeStartIssuesNoZoneWrites() async throws {
        let engine = FakeSyncEngine()
        _ = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        XCTAssertTrue(engine.databaseChanges.isEmpty)
    }

    func testSharedScopeAccountChangeIssuesNoZoneWrites() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)

        await transport.handleAccountChange(.switchAccounts(
            previousUser: CKRecord.ID(recordName: "_previous"),
            currentUser: CKRecord.ID(recordName: "_current")
        ))
        await transport.restartTask?.value

        let resets = await transport.accountResetCount
        XCTAssertEqual(resets, 1, "the account change must have run the reset")
        XCTAssertTrue(engine.databaseChanges.isEmpty)
    }

    func testSharedScopeResetIssuesNoZoneWrites() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)

        await transport.resetForAccountChange()
        await transport.restartTask?.value

        XCTAssertTrue(engine.databaseChanges.isEmpty)
    }

    func testSharedScopeRecordsAddressTheOwnersZones() async throws {
        let store = try TransportStore.inMemory()
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: store, scope: shared, engine: engine)

        try await transport.save([record("action-1")])

        guard case .saveRecord(let id) = engine.recordZoneChanges.first else {
            return XCTFail("save must schedule a record change")
        }
        XCTAssertEqual(id.zoneID.ownerName, owner)
        let batch = await transport.nextEngineBatch()
        XCTAssertEqual(batch?.recordsToSave.first?.recordID.zoneID.ownerName, owner)
    }

    // MARK: - Shared scope, unlinked

    func testSharedScopeZoneDeletedEmitsUnlinkedWithoutRecreatingZones() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)

        await transport.handleDeletedZones([shared.zoneID(for: .data), shared.zoneID(for: .relay)])

        XCTAssertEqual(collected.values, [.unlinked], "one event for one deletion batch")
        XCTAssertTrue(engine.databaseChanges.isEmpty)
    }

    func testSharedScopeIgnoresDeletionOfAnotherOwnersZone() async throws {
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared)
        let collected = await events(of: transport)

        await transport.handleDeletedZones([CKRecordZone.ID(zoneName: "DataZone", ownerName: "_someone-else")])

        XCTAssertTrue(collected.values.isEmpty)
    }

    func testPrivateScopeZoneDeletedRecreatesZoneAndStaysLinked() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        let collected = await events(of: transport)
        let before = engine.databaseChanges.count

        await transport.handleDeletedZones([CloudDatabaseScope.private.zoneID(for: .data)])

        XCTAssertTrue(collected.values.isEmpty)
        guard case .saveZone(let zone) = engine.databaseChanges.last, engine.databaseChanges.count == before + 1 else {
            return XCTFail("the private scope re-creates a deleted zone (unchanged branch behaviour)")
        }
        XCTAssertEqual(zone.zoneID.zoneName, "DataZone")
    }

    func testSharedScopeZoneNotFoundOnFetchEmitsUnlinked() async throws {
        let engine = FakeSyncEngine(fetchErrors: [CKError(.zoneNotFound)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)

        try await transport.pull()

        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testSharedScopeZoneNotFoundInsidePartialFailureEmitsUnlinked() async throws {
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [shared.zoneID(for: .relay): CKError(.zoneNotFound)]
        ])
        let engine = FakeSyncEngine(fetchErrors: [partial])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)

        try await transport.pull()

        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testSharedScopeChangeTokenExpiredOnExistingZoneRefetches() async throws {
        let engine = FakeSyncEngine(fetchErrors: [CKError(.changeTokenExpired)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)

        try await transport.pull()

        XCTAssertEqual(engine.fetchCount, 2, "an expired token on a live zone is re-fetched")
        XCTAssertTrue(collected.values.isEmpty)
    }

    func testSharedScopeChangeTokenExpiredOnMissingZoneEmitsUnlinked() async throws {
        let engine = FakeSyncEngine(existingZones: ["DataZone"], fetchErrors: [CKError(.changeTokenExpired)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)

        try await transport.pull()

        XCTAssertEqual(collected.values, [.unlinked])
        XCTAssertEqual(engine.fetchCount, 1, "no re-fetch of a zone that is gone")
    }

    func testSharedScopeZoneNotFoundOnSendEmitsUnlinked() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store, scope: shared)
        let collected = await events(of: transport)
        try await transport.save([record("action-1")])
        let next = await transport.nextEngineBatch()
        let batch = try XCTUnwrap(next)

        await transport.handleSentChanges(
            saved: [], deleted: [],
            failedSaves: batch.recordsToSave.map { ($0, CKError(.zoneNotFound)) },
            failedDeletes: [:]
        )

        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testPrivateScopeZoneNotFoundOnFetchIsRethrownNotUnlinked() async throws {
        let engine = FakeSyncEngine(fetchErrors: [CKError(.zoneNotFound)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        let collected = await events(of: transport)

        do {
            try await transport.pull()
            XCTFail("private scope keeps the branch behaviour: the fetch error surfaces")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .zoneNotFound)
        }
        XCTAssertTrue(collected.values.isEmpty)
    }

    // MARK: - Stored scope

    func testStartStoresTheScope() async throws {
        let store = try TransportStore.inMemory()
        _ = await CloudKitTransport.testing(store: store, scope: shared)
        XCTAssertEqual(try store.storedScope(), shared)
    }

    func testStartWithADifferentScopeWipesTheOldScopesState() async throws {
        let store = try TransportStore.inMemory()
        try store.saveScope(.private)
        try store.saveEngineState(Data("private-engine".utf8))
        try store.enqueueSave([record("action-1")])

        _ = await CloudKitTransport.testing(store: store, scope: shared)

        XCTAssertNil(try store.loadEngineState(), "a private-database engine state must not drive the shared database")
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty)
        XCTAssertEqual(try store.storedScope(), shared)
    }

    func testStartWithTheSameScopeKeepsState() async throws {
        let store = try TransportStore.inMemory()
        try store.saveScope(shared)
        try store.enqueueSave([record("action-1")])

        _ = await CloudKitTransport.testing(store: store, scope: shared)

        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["action-1"])
    }

    func testStoreWithoutARecordedScopeAdoptsItAndKeepsState() async throws {
        // Every hub store predates scopes: it must keep its queue and state.
        let store = try TransportStore.inMemory()
        try store.saveEngineState(Data("hub-engine".utf8))
        try store.enqueueSave([record("action-1")])

        _ = await CloudKitTransport.testing(store: store)

        XCTAssertEqual(try store.loadEngineState(), Data("hub-engine".utf8))
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["action-1"])
        XCTAssertEqual(try store.storedScope(), .private)
    }

    func testStoredScopeSurvivesAccountWipe() throws {
        let store = try TransportStore.inMemory()
        try store.saveScope(shared)
        try store.wipe()
        XCTAssertEqual(try store.storedScope(), shared)
    }
}
