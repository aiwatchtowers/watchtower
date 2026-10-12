import GRDB
import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// RelayFeed contract: the phone's SINGLE relay consumer (Plan 4 decision 3).
/// It owns the persisted relay token and fans records out in-process —
/// action echoes → ActionOutbox (own still-pending enqueues skipped). A
/// relay-zone heartbeat is ignored: liveness comes from the DataZone
/// heartbeat only (mobile POC spec §4.1). Unknown kinds and undecodable payloads are logged and skipped; the token
/// always advances at batch end (never wedge) with the replica's monotonic
/// stale-batch drop.
final class RelayFeedTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// The paired test phone and the test hub over one in-memory zone. The phone's outbox, feed and replica share
    /// one key store (`keys`), so a test can lock it; the hub seals its echoes to the phone.
    private struct Fixtures {
        let inner: any CloudSyncTransport & Sendable
        let keys: InMemoryPhoneKeyStore
        let transport: SecureTransport
        let hub: SecureTransport
        let store: ReplicaStore
        let outbox: ActionOutbox
        let feed: RelayFeed
    }

    private static let deviceID = TestE2E.deviceID.uuidString

    private func makeFixtures(
        inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport(),
        pull: (@Sendable () async throws -> Void)? = nil,
        onActionApplied: (@Sendable () async -> Void)? = nil
    ) throws -> Fixtures {
        let keys = try TestE2E.phoneStore()
        let transport = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: inner)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: Self.deviceID)
        let feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            pull: pull,
            onActionApplied: onActionApplied
        )
        return Fixtures(
            inner: inner, keys: keys, transport: transport, hub: TestE2E.hubTransport(inner: inner), store: store,
            outbox: outbox, feed: feed)
    }

    /// The desktop's rewrite of an action record carrying its verdict (the hub seals it on save).
    private func echoRecord(
        _ action: ActionRequestPayload,
        status: ActionStatus,
        errorMessage: String? = nil
    ) throws -> CloudRecord {
        var echo = action
        echo.status = status
        echo.errorMessage = errorMessage
        return try CloudRecordFactory.record(for: echo, modifiedAt: base)
    }

    /// Enqueues one action and returns the hub's `applied` rewrite of it,
    /// for tests that need any routable relay record.
    private func appliedEcho(_ f: Fixtures) async throws -> CloudRecord {
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        return try echoRecord(action, status: .applied)
    }

    private func deviceRecord() -> CloudRecord {
        CloudRecord(recordName: "device-\(Self.deviceID)", zone: .relay, kind: RelayRecordKind.device.rawValue,
                    modifiedAt: base, payload: Data("{}".utf8))
    }

    /// Lands a DataZone heartbeat in the replica the way hydration does: sealed by the test hub.
    private func hydrateHeartbeat(_ store: ReplicaStore, updatedAt: Date, token: Int = 1) throws {
        let record = try CloudRecordFactory.record(for: HeartbeatFixtures.minimal(updatedAt: updatedAt), modifiedAt: updatedAt)
        let sealed = try TestE2E.sealedDataRecord(record, wireName: HeartbeatPayload.recordName, seq: UInt64(token))
        try store.apply(CloudChangeBatch(changed: [sealed], deletedRecordNames: [], newToken: CloudChangeToken(value: token)))
    }

    // MARK: - Action echo routing

    func testAppliedEchoRemovesPendingOverlayRow() async throws {
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.hub.save([try echoRecord(action, status: .applied)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 1)
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
    }

    func testFailedEchoMarksOverlayRowFailed() async throws {
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-2")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.hub.save([try echoRecord(action, status: .failed, errorMessage: "inbox row 2 not found")])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 1)
        let row = try XCTUnwrap(f.store.pendingActions().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, "inbox row 2 not found")
    }

    func testOwnPendingEnqueueEchoIsSkipped() async throws {
        // Right after enqueue the feed sees our OWN record with status
        // pending — not a desktop verdict. It must not be routed, but the
        // token must still advance past it.
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .trackRead, entityRecordName: "track-3")

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 0)
        XCTAssertEqual(try XCTUnwrap(f.store.pendingActions().first).state, .pending)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    // MARK: - E2E: locked keychain and rollback (mobile E2E Review Focus 1)

    /// CloudKit delivers a hub echo while the phone is locked: the echo cannot be opened, so the poll throws
    /// `keysUnavailable`, nothing is applied and the token stays; after unlock the same batch applies.
    func testEchoesThatCannotBeOpenedWhileLockedAreReplayedAfterUnlock() async throws {
        let f = try makeFixtures()
        let id = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.hub.save([try echoRecord(action, status: .applied)])

        f.keys.isLocked = true
        do {
            _ = try await f.feed.pollOnce()
            XCTFail("a locked keychain must fail the cycle, never drop the echo")
        } catch SecureTransportError.keysUnavailable {
            // expected
        }
        XCTAssertNil(try f.store.relayToken(), "the token stays, so the batch replays")

        f.keys.isLocked = false
        XCTAssertEqual(try f.store.pendingActions().map(\.id), [id], "nothing was applied while locked")
        let routed = try await f.feed.pollOnce()

        XCTAssertEqual(routed, 1)
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 2))
    }

    /// The server re-presents an older version of an echo (`received`, hub seq 3) after the newer `applied`
    /// (hub seq 10): the rollback guard drops it before routing.
    func testARolledBackEchoIsIgnored() async throws {
        let f = try makeFixtures()
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        let newer = TestE2E.hubTransport(TestE2E.hub(firstSeq: 10), inner: f.inner)
        let older = TestE2E.hubTransport(TestE2E.hub(firstSeq: 3), inner: f.inner)
        try await newer.save([try echoRecord(action, status: .applied)])
        let applied = try await f.feed.pollOnce()
        XCTAssertEqual(applied, 1)

        try await older.save([try echoRecord(action, status: .received)])
        let rolledBack = try await f.feed.pollOnce()

        XCTAssertEqual(rolledBack, 0, "an older version of a seen echo is never routed")
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 3), "the token moves past it")
    }

    // MARK: - Heartbeat: DataZone only

    func testRelayZoneHeartbeatIsIgnored() async throws {
        // RelayZone is writable by a share participant, so a heartbeat there
        // must never prove liveness. A plaintext one never opens: SecureTransport
        // drops it before the feed, and the token still advances.
        let f = try makeFixtures()
        let legacy = try CloudRecordFactory.record(for: HeartbeatFixtures.minimal(updatedAt: base), modifiedAt: base)
        try await f.inner.save([
            CloudRecord(recordName: legacy.recordName, zone: .relay, kind: RelayRecordKind.heartbeat.rawValue,
                        modifiedAt: base, payload: legacy.payload)
        ])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 0)
        XCTAssertNil(try f.store.heartbeatAge(now: base))
        let logged = await f.feed.loggedUnknownKinds
        XCTAssertTrue(logged.isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    func testDeviceRecordIsIgnoredSilently() async throws {
        // The phone's own link record reflects back; the Mac consumes it.
        let f = try makeFixtures()
        try await f.transport.save([deviceRecord()])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 0)
        let logged = await f.feed.loggedUnknownKinds
        XCTAssertTrue(logged.isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
    }

    func testDataZoneHeartbeatSetsAge() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        try hydrateHeartbeat(store, updatedAt: base)

        XCTAssertEqual(try store.heartbeatAge(now: base.addingTimeInterval(300)), .seconds(300))
    }

    func testHeartbeatNeverSeenMeansUnreachable() async throws {
        let f = try makeFixtures()

        XCTAssertNil(try f.store.heartbeatAge(now: base))
        XCTAssertEqual(f.feed.desktopReachability(now: base), .unreachable)
    }

    func testDesktopReachableWhileHeartbeatIsUnder720Seconds() async throws {
        let f = try makeFixtures()
        try hydrateHeartbeat(f.store, updatedAt: base)

        XCTAssertEqual(f.feed.desktopReachability(now: base.addingTimeInterval(5 * 60)), .reachable)
        // Boundary: online while UNDER 720 s old (spec §3).
        XCTAssertEqual(f.feed.desktopReachability(now: base.addingTimeInterval(719)), .reachable)
        XCTAssertEqual(f.feed.desktopReachability(now: base.addingTimeInterval(720)), .unreachable)
    }

    /// The heartbeat is sealed: while the keychain is locked it cannot be read, and that is its own state,
    /// never "the Mac is offline" (mobile E2E Task 8 note on `heartbeatAge`).
    func testALockedKeychainIsNotAnUnreachableDesktop() async throws {
        let f = try makeFixtures()
        try hydrateHeartbeat(f.store, updatedAt: base)

        f.keys.isLocked = true
        XCTAssertEqual(f.feed.desktopReachability(now: base.addingTimeInterval(60)), .keysUnavailable)

        f.keys.isLocked = false
        XCTAssertEqual(f.feed.desktopReachability(now: base.addingTimeInterval(60)), .reachable)
    }

    func testHeartbeatWithFutureValuesStillYieldsAnAge() throws {
        // A newer Mac's heartbeat (new flavor, sharing state, account kind)
        // must keep an older phone's liveness working.
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        // swiftlint:disable:next line_length
        let json = #"{"accounts":[{"kind":"confluence","label":"acme","status":"connected"}],"app_version":"9.0.0","enabled_at":1700000000,"flavor":"partner","hub_id":"hub-1","mac_name":"Acme Mac","owner_user":"_owner","relay_backlog":0,"sharing":"paused","updated_at":1700000000}"#
        let record = CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat",
                                 modifiedAt: base, payload: Data(json.utf8))
        let sealed = try TestE2E.sealedDataRecord(record, wireName: HeartbeatPayload.recordName, seq: 1)
        try store.apply(CloudChangeBatch(changed: [sealed], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))

        XCTAssertEqual(try store.heartbeatAge(now: base.addingTimeInterval(60)), .seconds(60))
    }

    func testLivenessNeedsOnlyUpdatedAt() throws {
        // Liveness reads `updated_at` alone, so a field a future Mac drops or
        // reshapes can never turn the Mac offline.
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let record = CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat",
                                 modifiedAt: base, payload: Data(#"{"updated_at":1700000000}"#.utf8))
        let sealed = try TestE2E.sealedDataRecord(record, wireName: HeartbeatPayload.recordName, seq: 1)
        try store.apply(CloudChangeBatch(changed: [sealed], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))

        XCTAssertEqual(try store.heartbeatAge(now: base), .seconds(0))
    }

    func testUndecodableHeartbeatIsLoggedOnceNotPerRead() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let garbage = CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat",
                                  modifiedAt: base, payload: Data("not json".utf8))
        let sealed = try TestE2E.sealedDataRecord(garbage, wireName: HeartbeatPayload.recordName, seq: 1)
        try store.apply(CloudChangeBatch(changed: [sealed], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))

        for _ in 0..<3 {
            XCTAssertNil(try store.heartbeatAge(now: base))
        }
        XCTAssertEqual(store.undecodableHeartbeatLogCount(), 1)
    }

    func testUndecodableHeartbeatReadsAsNeverSeen() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let garbage = CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat",
                                  modifiedAt: base, payload: Data("not json".utf8))
        let sealed = try TestE2E.sealedDataRecord(garbage, wireName: HeartbeatPayload.recordName, seq: 1)
        try store.apply(CloudChangeBatch(changed: [sealed], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))

        XCTAssertNil(try store.heartbeatAge(now: base))
    }

    // MARK: - Unknown kinds / undecodable payloads

    /// Rewritten for E2E: a record nobody sealed for this phone (plaintext, an unknown kind) is dropped by
    /// SecureTransport and never reaches the feed's routing; the token still advances past it.
    func testUnopenableRecordsNeverReachTheFeedAndTheTokenAdvances() async throws {
        let f = try makeFixtures()
        func mystery(_ name: String) -> CloudRecord {
            CloudRecord(recordName: name, zone: .relay, kind: "mystery", modifiedAt: base, payload: Data("?".utf8))
        }
        try await f.inner.save([mystery("mystery-1")])

        let first = try await f.feed.pollOnce()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))

        try await f.inner.save([mystery("mystery-2")])
        _ = try await f.feed.pollOnce()
        let logged = await f.feed.loggedUnknownKinds
        XCTAssertTrue(logged.isEmpty, "dropped before routing")
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 2))
    }

    func testUndecodableKnownKindPayloadSkippedAndTokenStillAdvances() async throws {
        // Garbage payloads of KNOWN kinds must never wedge the feed: log,
        // skip, keep routing the rest of the batch, advance the token.
        // Sealed by the hub (so they open), but not a payload of their kind.
        let f = try makeFixtures()
        let garbage = Data(#"{"device_id":"\#(Self.deviceID)"}"#.utf8)
        let echo = try await appliedEcho(f)
        try await f.hub.save([
            CloudRecord(recordName: "action-X", zone: .relay, kind: RelayRecordKind.action.rawValue,
                        modifiedAt: base, payload: garbage),
            CloudRecord(recordName: "recupload-X", zone: .relay, kind: RelayRecordKind.recordingUpload.rawValue,
                        modifiedAt: base, payload: garbage),
            echo
        ])

        let result = try await f.feed.pollOnce()

        // The valid echo in the same batch still routed.
        XCTAssertEqual(result, 1)
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 4))

        // Token advanced past the garbage: the next poll sees nothing.
        let again = try await f.feed.pollOnce()
        XCTAssertEqual(again, 0)
    }

    // MARK: - Token persistence + monotonic guard

    func testTokenPersistsAndBatchIsNotRedelivered() async throws {
        let f = try makeFixtures()
        try await f.hub.save([try await appliedEcho(f)])

        let first = try await f.feed.pollOnce()
        let second = try await f.feed.pollOnce()

        // Delivered exactly once across the two polls.
        XCTAssertEqual(first + second, 1)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 2))
    }

    func testStaleBatchDroppedWholesaleBeforeRouting() async throws {
        // Monotonic drop mirrors the replica: a batch whose token is not
        // newer than the stored one must not be routed at all — replaying
        // records would re-fire echo side effects.
        let f = try makeFixtures()
        XCTAssertTrue(try f.store.setRelayToken(CloudChangeToken(value: 100)))
        try await f.hub.save([try await appliedEcho(f)])

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 0)
        XCTAssertEqual(try XCTUnwrap(f.store.pendingActions().first).state, .pending)
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 100))
    }

    // MARK: - Relay-buffer compaction (final-review i-F2)

    /// A TransportStore-backed feed compacts the consumed relay buffer: the
    /// phone is its only relay consumer, so events at or below the token it
    /// just persisted are dead weight in cloudkit-transport.sqlite.
    func testPollCompactsConsumedRelayEventsOfATransportStore() async throws {
        // F1: the feed reaches the buffer through SecureTransport's CompactingTransport conformance.
        let transportStore = try TransportStore.inMemory()
        let cloud = CloudKitTransport(store: transportStore, scope: .private, hubID: HubZones.testHubID, role: .phone)
        let f = try makeFixtures(inner: cloud)
        try transportStore.bufferChanged([try await f.transport.seal(deviceRecord())])
        try transportStore.bufferDeleted(recordNames: ["action-gone"], zone: .relay)

        _ = try await f.feed.pollOnce()

        let token = try XCTUnwrap(f.store.relayToken())
        XCTAssertEqual(token, CloudChangeToken(value: 2))
        let left = try transportStore.changes(in: .relay, since: nil)
        XCTAssertTrue(left.changed.isEmpty, "consumed relay events are compacted")
        XCTAssertTrue(left.deletedRecordNames.isEmpty, "consumed tombstones are compacted")
    }

    /// Compaction is hygiene: a failing compaction never fails a cycle
    /// whose token is already persisted.
    func testRelayCompactionFailureDoesNotFailThePoll() async throws {
        let transport = ThrowingRelayCompactTransport()
        let f = try makeFixtures(inner: transport)
        try await f.transport.save([deviceRecord()])

        _ = try await f.feed.pollOnce()

        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 1))
        let calls = await transport.compactCalls
        XCTAssertEqual(calls.map(\.zone), [.relay])
        XCTAssertEqual(calls.map(\.keepSince), [1])
    }

    private actor ThrowingRelayCompactTransport: CompactingTransport {
        private let inner = InMemoryCloudTransport()
        private(set) var compactCalls: [(zone: CloudZoneID, keepSince: Int)] = []
        struct CompactError: Error {}

        func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {
            try await inner.delete(recordNames: recordNames, in: zone)
        }
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            try await inner.changes(in: zone, since: token)
        }
        func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
            compactCalls.append((zone: zone, keepSince: token.value))
            throw CompactError()
        }
    }

    func testSetRelayTokenIsMonotonic() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())

        XCTAssertTrue(try store.setRelayToken(CloudChangeToken(value: 5)))
        XCTAssertFalse(try store.setRelayToken(CloudChangeToken(value: 3)))
        XCTAssertFalse(try store.setRelayToken(CloudChangeToken(value: 5)))
        XCTAssertEqual(try store.relayToken(), CloudChangeToken(value: 5))
        XCTAssertTrue(try store.setRelayToken(CloudChangeToken(value: 6)))
        XCTAssertEqual(try store.relayToken(), CloudChangeToken(value: 6))
    }

    func testRelayTokenIsIndependentOfDataToken() throws {
        // Decision 3: RelayFeed's cursor lives beside (not on top of) the
        // replica's data-zone cursor in replica_meta.
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        try store.setRelayToken(CloudChangeToken(value: 7))

        XCTAssertNil(try store.storedToken())
        XCTAssertEqual(try store.relayToken(), CloudChangeToken(value: 7))
    }

    // MARK: - Pull hook

    func testPullHookRunsBeforeChangesAreRead() async throws {
        let inner = InMemoryCloudTransport()
        let hub = TestE2E.hubTransport(inner: inner)
        let landed = OSAllocatedUnfairLock<CloudRecord?>(initialState: nil)
        // The pull hook lands the echo; pollOnce routes it in the same cycle
        // only if pull ran before changes().
        let pull: @Sendable () async throws -> Void = {
            if let record = landed.withLock({ $0 }) { try await hub.save([record]) }
        }
        let f = try makeFixtures(inner: inner, pull: pull)
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        let record = try echoRecord(action, status: .applied)
        landed.withLock { $0 = record }

        let routed = try await f.feed.pollOnce()

        XCTAssertEqual(routed, 1)
        XCTAssertTrue(try f.store.pendingActions().isEmpty)
    }

    // MARK: - Reentrancy coalescing

    /// Transport whose `changes` blocks on an external gate and counts calls,
    /// so two concurrent polls can be forced to overlap (template: ReplicaTests).
    private actor GatedTransport: CloudSyncTransport {
        private let inner = InMemoryCloudTransport()
        private(set) var changesCalls = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func seed(_ records: [CloudRecord]) async throws { try await inner.save(records) }

        func openGate() {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {
            try await inner.delete(recordNames: recordNames, in: zone)
        }

        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            changesCalls += 1
            await withCheckedContinuation { waiters.append($0) }
            return try await inner.changes(in: zone, since: token)
        }
    }

    func testConcurrentPollOnceCoalescesIntoOneCycle() async throws {
        let transport = GatedTransport()
        try await transport.seed([
            CloudRecord(recordName: "device-D1", zone: .relay, kind: RelayRecordKind.device.rawValue,
                        modifiedAt: base, payload: Data("{}".utf8))
        ])
        let feed = try makeFixtures(inner: transport).feed

        async let first = feed.pollOnce()
        async let second = feed.pollOnce()
        // Let both calls enter and the first suspend inside changes().
        try await Task.sleep(for: .milliseconds(50))
        await transport.openGate()

        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        // Coalesced: exactly one real cycle ran, so changes() was hit once.
        let calls = await transport.changesCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - onActionApplied hook

    func testOnActionAppliedFiresAfterTokenIsPersisted() async throws {
        let inner = InMemoryCloudTransport()
        let keys = try TestE2E.phoneStore()
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let fired = expectation(description: "hook fired")
        let tokenAtFire = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let hook: @Sendable () async -> Void = {
            // try? flattens relayToken's own nil into the same branch.
            if let token = try? store.relayToken() {
                tokenAtFire.withLock { $0 = token.value }
            }
            fired.fulfill()
        }
        let transport = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: inner)
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: Self.deviceID)
        let feed = RelayFeed(transport: transport, store: store, outbox: outbox, onActionApplied: hook)
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(store.pendingActions().first).action
        let hub = TestE2E.hubTransport(inner: inner)
        try await hub.save([try echoRecord(action, status: .applied)])

        _ = try await feed.pollOnce()

        await fulfillment(of: [fired], timeout: 5)
        // The hook exists to trigger re-hydration (Task 6); it must observe
        // the already-persisted token, never a pre-batch one.
        XCTAssertEqual(tokenAtFire.withLock { $0 }, 2)
    }

    func testOnActionAppliedNotFiredForPendingOrFailedEchoes() async throws {
        let hookCalls = OSAllocatedUnfairLock(initialState: 0)
        let fired = expectation(description: "hook fired for the applied echo")
        let hook: @Sendable () async -> Void = {
            hookCalls.withLock { $0 += 1 }
            fired.fulfill()
        }
        let f = try makeFixtures(onActionApplied: hook)

        // Own pending enqueue echo: no fire.
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        _ = try await f.feed.pollOnce()
        // Failed echo: no fire.
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.hub.save([try echoRecord(action, status: .failed, errorMessage: "no")])
        _ = try await f.feed.pollOnce()
        // Applied echo: exactly this one fires.
        try await f.hub.save([try echoRecord(action, status: .applied)])
        _ = try await f.feed.pollOnce()

        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(hookCalls.withLock { $0 }, 1)
    }

    func testTwoAppliedEchoesInOneBatchFireHookExactlyOnce() async throws {
        // One fire per batch is enough — the consumer re-hydrates everything
        // anyway. The expectation's default assertForOverFulfill turns a
        // second fire into a failure.
        let hookCalls = OSAllocatedUnfairLock(initialState: 0)
        let fired = expectation(description: "hook fired once for the whole batch")
        let hook: @Sendable () async -> Void = {
            hookCalls.withLock { $0 += 1 }
            fired.fulfill()
        }
        let f = try makeFixtures(onActionApplied: hook)
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        _ = try await f.outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-2")
        _ = try await f.feed.pollOnce() // consume the two own-pending reflections
        for pending in try f.store.pendingActions() {
            try await f.hub.save([try echoRecord(pending.action, status: .applied)])
        }

        let result = try await f.feed.pollOnce()

        XCTAssertEqual(result, 2)
        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(hookCalls.withLock { $0 }, 1)
    }

    /// Gate the hook can hang on, so the test can prove a slow hook never
    /// blocks the feed.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    func testSlowHookDoesNotBlockPollOnceOrTheNextPoll() async throws {
        let gate = Gate()
        let finished = expectation(description: "slow hook eventually finished")
        let hook: @Sendable () async -> Void = {
            await gate.wait()
            finished.fulfill()
        }
        let f = try makeFixtures(onActionApplied: hook)
        _ = try await f.outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        let action = try XCTUnwrap(f.store.pendingActions().first).action
        try await f.hub.save([try echoRecord(action, status: .applied)])

        // pollOnce returns while the hook is still hung on the gate
        // (fire-and-forget), and the NEXT poll runs to completion too.
        let first = try await f.feed.pollOnce()
        XCTAssertEqual(first, 1)
        try await f.transport.save([
            CloudRecord(recordName: "device-D1", zone: .relay, kind: RelayRecordKind.device.rawValue,
                        modifiedAt: base, payload: Data("{}".utf8))
        ])
        _ = try await f.feed.pollOnce()
        XCTAssertEqual(try f.store.relayToken(), CloudChangeToken(value: 3))

        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
    }
}
