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

    func testUnlinkedIsTerminal() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)
        try await transport.save([record("action-1")])
        let next = await transport.nextEngineBatch()
        let batch = try XCTUnwrap(next)
        let zoneGone = batch.recordsToSave.map { ($0, CKError(.zoneNotFound)) }

        await transport.handleSentChanges(saved: [], deleted: [], failedSaves: zoneGone, failedDeletes: [:])
        let nudgesAtUnlink = engine.recordZoneChanges.count

        let afterUnlink = await transport.nextEngineBatch()
        XCTAssertNil(afterUnlink, "no sends into a zone that is gone")
        try await transport.save([record("action-2")])
        XCTAssertEqual(engine.recordZoneChanges.count, nudgesAtUnlink, "no nudges after unlinked")
        await transport.handleSentChanges(saved: [], deleted: [], failedSaves: zoneGone, failedDeletes: [:])
        try await transport.pull()
        XCTAssertEqual(engine.fetchCount, 0, "no fetches after unlinked")
        let unlinked = await transport.isUnlinked
        XCTAssertTrue(unlinked)
        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testForeignOwnersZoneNotFoundInPartialFailureDoesNotUnlink() async throws {
        let stale = CKRecordZone.ID(zoneName: "RelayZone", ownerName: "_stale-owner")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [stale: CKError(.zoneNotFound)]])
        let engine = FakeSyncEngine(fetchErrors: [partial])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)

        try await transport.pull()

        XCTAssertTrue(collected.values.isEmpty, "another Mac's vanished zone never unlinks this link")
    }

    func testEventPathZoneNotFoundUnlinksOnlyForTheOwner() async throws {
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared)
        let collected = await events(of: transport)

        await transport.handleFetchEventError(
            CKError(.zoneNotFound),
            zoneID: CKRecordZone.ID(zoneName: "DataZone", ownerName: "_stale-owner")
        )
        XCTAssertTrue(collected.values.isEmpty)

        await transport.handleFetchEventError(CKError(.zoneNotFound), zoneID: shared.zoneID(for: .data))
        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testEventPathExpiredTokenRefetchesOnce() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)

        await transport.handleFetchEventError(CKError(.changeTokenExpired), zoneID: shared.zoneID(for: .relay))

        XCTAssertEqual(engine.fetchCount, 1)
        XCTAssertEqual(engine.zoneQueryCount, 1)
    }

    func testErrorBothThrownAndDeliveredAsAnEventIsHandledOnce() async throws {
        let engine = FakeSyncEngine(fetchErrors: [CKError(.changeTokenExpired)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let zone = shared.zoneID(for: .relay)
        engine.onNextFetch { await transport.handleFetchEventError(CKError(.changeTokenExpired), zoneID: zone) }

        try await transport.pull()

        XCTAssertEqual(engine.fetchCount, 2, "the pull's fetch plus ONE re-fetch")
        XCTAssertEqual(engine.zoneQueryCount, 1)
    }

    func testEventOnlyErrorDuringAPullIsHandledByThePull() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)
        let zone = shared.zoneID(for: .data)
        engine.onNextFetch { await transport.handleFetchEventError(CKError(.zoneNotFound), zoneID: zone) }

        try await transport.pull()

        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testThrownBareZoneNotFoundKeepsTheParkedEventsForeignZone() async throws {
        // The engine throws a bare error and reports the zone in the event:
        // the zone must not be lost, or a stale owner unlinks the live link.
        let engine = FakeSyncEngine(fetchErrors: [CKError(.zoneNotFound)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)
        let stale = CKRecordZone.ID(zoneName: "DataZone", ownerName: "_stale-owner")
        engine.onNextFetch { await transport.handleFetchEventError(CKError(.zoneNotFound), zoneID: stale) }

        try await transport.pull()

        XCTAssertTrue(collected.values.isEmpty)
    }

    /// From inside the fake's fetch: starts a second pull in its own task
    /// and waits until it has joined the running one. Returns that task.
    private func startJoiningPull(
        _ transport: CloudKitTransport,
        order: Collector<String>
    ) async -> Task<Error?, Never> {
        let inner = Task<Error?, Never> {
            do {
                try await transport.pull()
                order.append("inner done")
                return nil
            } catch {
                order.append("inner done")
                return error
            }
        }
        for _ in 0..<10_000 where await transport.pullJoins == 0 {
            await Task.yield()
        }
        order.append("fetch ending")
        return inner
    }

    func testAPullDuringAPullJoinsIt() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let order = Collector<String>()
        let innerBox = Collector<Task<Error?, Never>>()
        engine.onNextFetch { innerBox.append(await self.startJoiningPull(transport, order: order)) }

        try await transport.pull()
        let innerError = await innerBox.values.first?.value

        let joins = await transport.pullJoins
        XCTAssertEqual(joins, 1, "the second pull joined the running one")
        XCTAssertNil(innerError)
        XCTAssertEqual(engine.fetchCount, 1, "one fetch for both callers")
        XCTAssertEqual(order.values, ["fetch ending", "inner done"], "the joiner returns only after the running fetch")
    }

    func testAJoiningPullGetsTheRunningPullsError() async throws {
        let engine = FakeSyncEngine(fetchErrors: [CKError(.networkFailure)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let order = Collector<String>()
        let innerBox = Collector<Task<Error?, Never>>()
        engine.onNextFetch { innerBox.append(await self.startJoiningPull(transport, order: order)) }

        do {
            try await transport.pull()
            XCTFail("the network failure surfaces")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .networkFailure)
        }
        let innerError = await innerBox.values.first?.value

        XCTAssertEqual((innerError as? CKError)?.code, .networkFailure, "the joiner gets the same outcome")
        XCTAssertEqual(engine.fetchCount, 1)
    }

    func testThrownBareZoneNotFoundIsOursWhenAnyParkedZoneIsOurs() async throws {
        // The live owner's zone and a stale owner's same-named zone are both
        // gone; the stale event is parked last. The thrown bare error must
        // still count for the live link.
        let engine = FakeSyncEngine(fetchErrors: [CKError(.zoneNotFound)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)
        let live = shared.zoneID(for: .data)
        let stale = CKRecordZone.ID(zoneName: "DataZone", ownerName: "_stale-owner")
        engine.onNextFetch {
            await transport.handleFetchEventError(CKError(.zoneNotFound), zoneID: live)
            await transport.handleFetchEventError(CKError(.zoneNotFound), zoneID: stale)
        }

        try await transport.pull()

        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testAPullThatEndsUnlinkedDoesNotThrow() async throws {
        // Expired token → re-fetch; during the re-fetch the event path
        // reports the zone gone, and the re-fetch then throws zoneNotFound.
        let engine = FakeSyncEngine(fetchErrors: [CKError(.changeTokenExpired), CKError(.zoneNotFound)])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine)
        let collected = await events(of: transport)
        let zone = shared.zoneID(for: .relay)
        engine.onNextFetch {
            engine.onNextFetch { await transport.handleFetchEventError(CKError(.zoneNotFound), zoneID: zone) }
        }

        try await transport.pull()

        XCTAssertEqual(engine.fetchCount, 2)
        XCTAssertEqual(collected.values, [.unlinked])
    }

    func testPrivateScopeIgnoresEventPathErrors() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        let zone = CloudDatabaseScope.private.zoneID(for: .data)

        await transport.handleFetchEventError(CKError(.networkFailure), zoneID: zone)
        await transport.handleFetchEventError(CKError(.changeTokenExpired), zoneID: zone)

        let lastError = await transport.lastError
        XCTAssertNil(lastError, "a transient automatic-fetch error must not flip availability()")
        XCTAssertEqual(engine.fetchCount, 0, "unchanged: the engine retries its own fetches")
    }

    func testThrottleOnTheZoneCheckIsAThrottle() async throws {
        let engine = FakeSyncEngine(
            fetchErrors: [CKError(.changeTokenExpired)],
            zoneQueryErrors: [CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 4.0])]
        )
        let sleeps = Collector<TimeInterval>()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), scope: shared, engine: engine, sleeps: sleeps)
        let collected = await events(of: transport)

        try await transport.pull()
        await transport.retryTask?.value

        XCTAssertEqual(sleeps.values, [4])
        XCTAssertTrue(collected.values.isEmpty)
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
