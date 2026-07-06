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
