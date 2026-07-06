import GRDB
import XCTest
@testable import WatchtowerKit

/// End-to-end coverage for the mobile DataZone mirror: real RowPayloadCoder
/// payloads flow through InMemoryCloudTransport into ReplicaStore, and come
/// back out as decoded models via fetchAll.
final class ReplicaTests: XCTestCase {

    // MARK: - Fixtures

    /// A realistic targets row: only `id` is structurally required by
    /// Target.init(row:); the rest exercises typed decode assertions.
    private func targetRow(id: Int, text: String, status: String = "todo") -> Row {
        Row([
            "id": id,
            "text": text,
            "intent": "build",
            "level": "week",
            "period_start": "2026-07-06",
            "period_end": "2026-07-12",
            "status": status,
            "priority": "high",
            "ownership": "mine",
            "progress": 0.4,
            "source_type": "manual",
            "created_at": "2026-07-06T10:00:00Z",
            "updated_at": "2026-07-06T11:00:00Z"
        ])
    }

    private func inboxRow(id: Int, snippet: String) -> Row {
        Row([
            "id": id,
            "channel_id": "C042",
            "message_ts": "1720000000.000100",
            "trigger_type": "dm",
            "snippet": snippet,
            "status": "pending",
            "priority": "high",
            "item_class": "actionable",
            "pinned": 1
        ])
    }

    private func dataRecord(kind: SliceKind, id: String, payload: Data) -> CloudRecord {
        CloudRecord(
            recordName: kind.recordName(id: id),
            zone: .data,
            kind: kind.rawValue,
            modifiedAt: Date(timeIntervalSince1970: 1_720_000_000),
            payload: payload
        )
    }

    // MARK: - Hydrate + decode

    func testHydrateDecodesRealTargetAndInboxPayloads() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "7",
                       payload: try RowPayloadCoder.payload(from: targetRow(id: 7, text: "Ship the replica", status: "in_progress"))),
            dataRecord(kind: .inboxItem, id: "3",
                       payload: try RowPayloadCoder.payload(from: inboxRow(id: 3, snippet: "can you check the deploy?")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)

        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.applied, 2)
        XCTAssertEqual(result.deleted, 0)

        let targets = try store.fetchAll(Target.self, kind: .target)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].id, 7)
        XCTAssertEqual(targets[0].text, "Ship the replica")
        XCTAssertEqual(targets[0].status, "in_progress")
        XCTAssertEqual(targets[0].priority, "high")
        XCTAssertEqual(targets[0].progress, 0.4)
        XCTAssertEqual(targets[0].periodStart, "2026-07-06")

        let items = try store.fetchAll(InboxItem.self, kind: .inboxItem)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, 3)
        XCTAssertEqual(items[0].snippet, "can you check the deploy?")
        XCTAssertTrue(items[0].isDM)
        XCTAssertTrue(items[0].pinned)
        XCTAssertEqual(items[0].itemClass, .actionable)
        XCTAssertEqual(store.corruptCount(), 0)
    }

    // MARK: - Token advancement

    func testTokenAdvancesAndSecondHydrateAppliesNothing() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "once")))
        ])
        let store = try ReplicaStore.inMemory()
        XCTAssertNil(try store.storedToken())

        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(try store.storedToken(), CloudChangeToken(value: 1))

        let second = try await hydrator.hydrateOnce()
        XCTAssertEqual(second.applied, 0)
        XCTAssertEqual(second.deleted, 0)

        // The token lives in the store, not the hydrator: a fresh hydrator
        // over the same store must not re-apply.
        let fresh = ReplicaHydrator(transport: transport, store: store)
        let replay = try await fresh.hydrateOnce()
        XCTAssertEqual(replay.applied, 0)
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).count, 1)
    }

    // MARK: - Deletion

    func testDeletionPropagatesToReplica() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "doomed")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).count, 1)

        try await transport.delete(recordNames: [SliceKind.target.recordName(id: "1")], in: .data)
        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.deleted, 1)
        XCTAssertTrue(try store.fetchAll(Target.self, kind: .target).isEmpty)
    }

    // MARK: - Sort order

    /// Pins that `ReplicaSort` cases actually change fetch order — the old
    /// String sort-fragment param had zero order-variation coverage. Ids and
    /// modifiedAt are deliberately staggered so record_name order,
    /// newestFirst, and oldestFirst each produce a distinct sequence.
    func testFetchAllSortOrdersDiffer() throws {
        let store = try ReplicaStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        try store.apply(CloudChangeBatch(
            changed: [
                CloudRecord(recordName: SliceKind.target.recordName(id: "1"), zone: .data, kind: SliceKind.target.rawValue,
                            modifiedAt: base.addingTimeInterval(300),
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "newest"))),
                CloudRecord(recordName: SliceKind.target.recordName(id: "2"), zone: .data, kind: SliceKind.target.rawValue,
                            modifiedAt: base.addingTimeInterval(100),
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 2, text: "oldest"))),
                CloudRecord(recordName: SliceKind.target.recordName(id: "3"), zone: .data, kind: SliceKind.target.rawValue,
                            modifiedAt: base.addingTimeInterval(200),
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 3, text: "middle")))
            ],
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)
        ))

        let newest = try store.fetchAll(Target.self, kind: .target, sort: .newestFirst)
        XCTAssertEqual(newest.map(\.id), [1, 3, 2])

        let oldest = try store.fetchAll(Target.self, kind: .target, sort: .oldestFirst)
        XCTAssertEqual(oldest.map(\.id), [2, 3, 1])

        let byName = try store.fetchAll(Target.self, kind: .target, sort: .recordName)
        XCTAssertEqual(byName.map(\.id), [1, 2, 3])

        // Default (no explicit sort) must stay newestFirst — the behavior
        // every existing call site relies on.
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).map(\.id), [1, 3, 2])
    }

    /// Pins the `, record_name` tie-break half of the time-based sorts: two
    /// records sharing one modifiedAt must order by record_name in BOTH
    /// directions — a regression dropping the secondary key ships undetected
    /// by testFetchAllSortOrdersDiffer (its stamps are all distinct).
    func testFetchAllTimeSortsTieBreakByRecordName() throws {
        let store = try ReplicaStore.inMemory()
        let stamp = Date(timeIntervalSince1970: 1_720_000_000)
        try store.apply(CloudChangeBatch(
            changed: [
                CloudRecord(recordName: SliceKind.target.recordName(id: "9"), zone: .data, kind: SliceKind.target.rawValue,
                            modifiedAt: stamp,
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 9, text: "tie-b"))),
                CloudRecord(recordName: SliceKind.target.recordName(id: "8"), zone: .data, kind: SliceKind.target.rawValue,
                            modifiedAt: stamp,
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 8, text: "tie-a")))
            ],
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: 1)
        ))

        // Same timestamp → record_name ("target-8" < "target-9") decides,
        // identically for both time-based directions.
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target, sort: .newestFirst).map(\.id), [8, 9])
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target, sort: .oldestFirst).map(\.id), [8, 9])
    }

    // MARK: - Relay records ignored

    func testApplyIgnoresRelayZoneRecords() throws {
        let store = try ReplicaStore.inMemory()
        let relay = CloudRecord(
            recordName: "action-R1",
            zone: .relay,
            kind: "action",
            modifiedAt: Date(),
            payload: Data("{}".utf8)
        )
        let data = dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "kept")))
        try store.apply(CloudChangeBatch(changed: [relay, data], deletedRecordNames: [], newToken: CloudChangeToken(value: 2)))

        let names = try store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT record_name FROM slice_records ORDER BY record_name")
        }
        XCTAssertEqual(names, ["target-1"])
        // Token still persisted — ignoring relay records is not an error.
        XCTAssertEqual(try store.storedToken(), CloudChangeToken(value: 2))
    }

    func testHydratorNeverReadsRelayZone() async throws {
        let transport = InMemoryCloudTransport()
        let relay = CloudRecord(
            recordName: "chat-1",
            zone: .relay,
            kind: "chat_message",
            modifiedAt: Date(),
            payload: Data("{}".utf8)
        )
        try await transport.save([relay])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)

        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.deleted, 0)
        let count = try await store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Corrupt payloads

    func testCorruptPayloadIsSkippedCountedAndDoesNotWedgeHydration() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "1", payload: Data("not json".utf8)),
            dataRecord(kind: .target, id: "2", payload: try RowPayloadCoder.payload(from: targetRow(id: 2, text: "good")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)

        // apply stores payload blobs without decoding, so a corrupt payload
        // never fails the batch — corruption surfaces (and is skipped) at read.
        let first = try await hydrator.hydrateOnce()
        XCTAssertEqual(first.applied, 2)

        let targets = try store.fetchAll(Target.self, kind: .target)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].text, "good")
        XCTAssertEqual(store.corruptCount(), 1)

        // Re-fetching the same persistently-corrupt row must not inflate the
        // distinct count (nor re-log) — corruptCount tracks record_names.
        _ = try store.fetchAll(Target.self, kind: .target)
        XCTAssertEqual(store.corruptCount(), 1)

        // The token advanced past the corrupt record: hydration is not wedged.
        let second = try await hydrator.hydrateOnce()
        XCTAssertEqual(second.applied, 0)
    }

    // MARK: - ValueObservation

    func testValueObservationFiresAfterApply() throws {
        let store = try ReplicaStore.inMemory()
        let observed = expectation(description: "observation sees the applied row")
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        let cancellable = observation.start(
            in: store.reader,
            onError: { XCTFail("observation error: \($0)") },
            onChange: { count in
                if count == 1 { observed.fulfill() }
            }
        )
        defer { cancellable.cancel() }

        let record = dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "observed")))
        try store.apply(CloudChangeBatch(changed: [record], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))
        wait(for: [observed], timeout: 5)
    }

    // MARK: - Compaction

    /// Spy: delegates transport calls to InMemoryCloudTransport, records compact().
    private actor CompactSpyTransport: CompactingTransport {
        private let inner = InMemoryCloudTransport()
        private(set) var compactCalls: [(zone: CloudZoneID, keepSince: Int)] = []

        func save(_ records: [CloudRecord]) async throws {
            try await inner.save(records)
        }

        func delete(recordNames: [String], in zone: CloudZoneID) async throws {
            try await inner.delete(recordNames: recordNames, in: zone)
        }

        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            try await inner.changes(in: zone, since: token)
        }

        func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
            compactCalls.append((zone: zone, keepSince: token.value))
        }
    }

    func testHydrateCompactsDataZoneAfterApply() async throws {
        let transport = CompactSpyTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "compacted")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()

        // Compaction floor must be the token the replica just persisted:
        // .data only (relay retention belongs to desktop hygiene), and only
        // after apply succeeded.
        let calls = await transport.compactCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].zone, .data)
        XCTAssertEqual(calls[0].keepSince, try XCTUnwrap(store.storedToken()).value)
    }

    // MARK: - Pull hook

    func testPullHookRunsBeforeChangesAreRead() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let record = dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "pulled")))
        // The pull hook lands the record; hydrateOnce sees it in the same
        // cycle only if pull ran before changes().
        let hydrator = ReplicaHydrator(transport: transport, store: store) {
            try await transport.save([record])
        }
        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).first?.text, "pulled")
    }

    // MARK: - Monotonic apply guard

    func testApplyDropsStaleBatchAndKeepsNewerPayload() throws {
        let store = try ReplicaStore.inMemory()
        let v2 = dataRecord(kind: .target, id: "1",
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "v2")))
        XCTAssertTrue(try store.apply(CloudChangeBatch(changed: [v2], deletedRecordNames: [], newToken: CloudChangeToken(value: 5))))

        // A later-arriving OLDER batch (token 3 <= stored 5) with an earlier
        // version of the same record must be dropped wholesale.
        let v1 = dataRecord(kind: .target, id: "1",
                            payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "v1")))
        XCTAssertFalse(try store.apply(CloudChangeBatch(changed: [v1], deletedRecordNames: [], newToken: CloudChangeToken(value: 3))))

        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).first?.text, "v2")
        XCTAssertEqual(try store.storedToken(), CloudChangeToken(value: 5))
    }

    // MARK: - Reentrancy coalescing

    /// Transport whose `changes` blocks on an external gate and counts calls,
    /// so two concurrent hydrate cycles can be forced to overlap.
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

    func testConcurrentHydrateOnceCoalescesIntoOneCycle() async throws {
        let transport = GatedTransport()
        try await transport.seed([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "gated")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)

        async let first = hydrator.hydrateOnce()
        async let second = hydrator.hydrateOnce()
        // Let both calls enter and the first suspend inside changes().
        try await Task.sleep(for: .milliseconds(50))
        await transport.openGate()

        let (a, b) = try await (first, second)
        XCTAssertEqual(a.applied, b.applied)
        // Coalesced: exactly one real cycle ran, so changes() was hit once.
        let calls = await transport.changesCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - DatabasePool (production mechanism) path

    func testHydrateAndObserveOnDatabasePoolPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replica-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = InMemoryCloudTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "on disk")))
        ])
        let store = try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)

        let observed = expectation(description: "pool observation sees the row")
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        let cancellable = observation.start(
            in: store.reader,
            onError: { XCTFail("observation error: \($0)") },
            onChange: { if $0 == 1 { observed.fulfill() } }
        )
        defer { cancellable.cancel() }

        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()

        await fulfillment(of: [observed], timeout: 5)
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).first?.text, "on disk")
    }

    /// The exact scenario ReplicaObserver drives: a ValueObservation whose
    /// tracking closure calls `fetchAll(_:kind:from:)` on the closure's OWN
    /// pool-reader `db`. The old code nested `fetchAll(_:kind:)` (which opens
    /// `writer.read`) inside the closure and trapped on DatabasePool
    /// reentrancy. This asserts the overload does NOT trap and DOES track the
    /// region — the observation fires with the decoded model after apply.
    func testObservationDecodesViaFromDbOverloadOnPoolPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replica-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)

        let observed = expectation(description: "observation decodes the applied target")
        // Tracking closure decodes on its own db — NOT store.fetchAll(_:kind:),
        // which would open a nested writer.read and fatalError on the pool.
        let observation = ValueObservation.tracking { db -> [Target] in
            try store.fetchAll(Target.self, kind: .target, from: db)
        }
        let cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { XCTFail("observation error: \($0)") },
            onChange: { targets in
                if targets.first?.text == "observed via from-db" { observed.fulfill() }
            }
        )
        defer { cancellable.cancel() }

        let record = dataRecord(kind: .target, id: "1",
                                payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "observed via from-db")))
        try store.apply(CloudChangeBatch(changed: [record], deletedRecordNames: [], newToken: CloudChangeToken(value: 1)))

        await fulfillment(of: [observed], timeout: 5)
    }

    // MARK: - Compaction failure is non-fatal

    private actor ThrowingCompactTransport: CompactingTransport {
        private let inner = InMemoryCloudTransport()
        struct CompactError: Error {}

        func seed(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {
            try await inner.delete(recordNames: recordNames, in: zone)
        }
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            try await inner.changes(in: zone, since: token)
        }
        func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws {
            throw CompactError()
        }
    }

    func testCompactionFailureDoesNotFailAppliedCycle() async throws {
        let transport = ThrowingCompactTransport()
        try await transport.seed([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "applied")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)

        // compact throws, but the cycle already applied — it must succeed.
        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).first?.text, "applied")
    }

    // MARK: - Loop

    func testStartLoopHydratesAndStopCancels() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([
            dataRecord(kind: .target, id: "1", payload: try RowPayloadCoder.payload(from: targetRow(id: 1, text: "looped")))
        ])
        let store = try ReplicaStore.inMemory()
        let hydrator = ReplicaHydrator(transport: transport, store: store)

        await hydrator.start(interval: .milliseconds(10))
        let deadline = Date().addingTimeInterval(5)
        while try store.fetchAll(Target.self, kind: .target).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await hydrator.stop()
        XCTAssertEqual(try store.fetchAll(Target.self, kind: .target).count, 1)
    }
}
