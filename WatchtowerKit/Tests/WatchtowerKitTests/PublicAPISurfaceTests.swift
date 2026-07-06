/// Plain-import compile gate for the iOS app's public WatchtowerKit surface.
///
/// NO @testable. Every symbol referenced here must be public.
/// If this file fails to compile, the iOS app would also fail to build.
///
/// Coverage: transport protocols, relay entry points, replica-relevant models.
/// Intentionally NOT exhaustive — it exercises what list UIs and relay
/// round-trips actually use, not every helper on every type.
///
/// GRDB is imported the way the iOS app imports it — alongside the Kit, for
/// Row (payload building) and ValueObservation over ReplicaStore.reader.
import GRDB
import WatchtowerKit
import XCTest

final class PublicAPISurfaceTests: XCTestCase {

    // MARK: - CloudSyncTransport protocol + InMemoryCloudTransport

    func testCloudSyncTransportViaInMemory() async throws {
        // InMemoryCloudTransport is the iOS app's test double for CloudKitTransport.
        // Construct through the protocol seam to prove the conformance is public.
        let transport: any CloudSyncTransport = InMemoryCloudTransport()

        let record = CloudRecord(
            recordName: "target-1",
            zone: .data,
            kind: "target",
            modifiedAt: Date(),
            payload: Data()
        )
        try await transport.save([record])
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.count, 1)
        XCTAssertEqual(batch.changed[0].recordName, record.recordName)
        XCTAssertEqual(batch.newToken.value, 1)

        try await transport.delete(recordNames: ["target-1"], in: .data)
        let afterDelete = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(afterDelete.deletedRecordNames.contains("target-1"))
    }

    // MARK: - SliceRecord + SliceKind

    func testSliceRecordConstruction() {
        let record = SliceRecord(
            kind: .target,
            id: "42",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data("{}".utf8)
        )
        XCTAssertEqual(record.recordName, "target-42")
        XCTAssertEqual(record.kind, .target)
        XCTAssertEqual(record.id, "42")
    }

    // MARK: - RelayCoder

    func testRelayCoderRoundTrip() throws {
        let action = ActionRequestPayload(
            id: "ios-test-1",
            kind: .targetDone,
            entityID: "99",
            params: [:],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try RelayCoder.makeEncoder().encode(action)
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: data)
        XCTAssertEqual(decoded.id, action.id)
        XCTAssertEqual(decoded.kind, action.kind)
        XCTAssertEqual(decoded.entityID, action.entityID)
    }

    // MARK: - CloudRecordFactory

    func testCloudRecordFactoryForSlice() {
        let slice = SliceRecord(kind: .inboxItem, id: "7", modifiedAt: Date(), payload: Data())
        let cloudRecord = CloudRecordFactory.record(for: slice)
        XCTAssertEqual(cloudRecord.recordName, "inbox_item-7")
        XCTAssertEqual(cloudRecord.zone, .data)
    }

    func testCloudRecordFactoryForRelay() throws {
        let action = ActionRequestPayload(
            id: "R1",
            kind: .inboxResolve,
            entityID: "5",
            params: [:],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let cloudRecord = try CloudRecordFactory.record(for: action, modifiedAt: action.createdAt)
        XCTAssertEqual(cloudRecord.recordName, "action-R1")
        XCTAssertEqual(cloudRecord.zone, .relay)
    }

    // MARK: - Target model fields (list UI)

    func testTargetPublicFields() {
        // Verify the fields list UIs read are publicly accessible.
        // Build via init(row:) is internal — use the public Codable init instead.
        // Just compile-check that the field names exist and have the expected types.
        let keyPath1: KeyPath<Target, String> = \.text
        let keyPath2: KeyPath<Target, String> = \.status
        let keyPath3: KeyPath<Target, String> = \.priority
        // Suppress unused-variable warnings; the point is the compile, not the value.
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - InboxItem model fields (feed UI)

    func testInboxItemPublicFields() {
        let keyPath1: KeyPath<InboxItem, String> = \.snippet
        let keyPath2: KeyPath<InboxItem, String> = \.status
        let keyPath3: KeyPath<InboxItem, Bool> = \.pinned
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - Track model fields (track list)

    func testTrackPublicFields() {
        let keyPath1: KeyPath<Track, String> = \.text
        let keyPath2: KeyPath<Track, String> = \.category
        let keyPath3: KeyPath<Track, String> = \.priority
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - Briefing model fields

    func testBriefingPublicFields() {
        let keyPath1: KeyPath<Briefing, String> = \.date
        let keyPath2: KeyPath<Briefing, Bool> = \.isRead
        _ = keyPath1; _ = keyPath2
    }

    // MARK: - CalendarEvent model fields

    func testCalendarEventPublicFields() {
        let keyPath1: KeyPath<CalendarEvent, String> = \.title
        let keyPath2: KeyPath<CalendarEvent, String> = \.startTime
        let keyPath3: KeyPath<CalendarEvent, Bool> = \.isAllDay
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - TransportStore public surface

    func testTransportStorePublicInit() throws {
        // Only init(path:) and inMemory() are public — the adapter internals are internal.
        let store = try TransportStore.inMemory()
        // wipe() and compactEvents(in:keepSince:) stay public (reset path + CompactingTransport).
        try store.wipe()
        try store.compactEvents(in: .data, keepSince: CloudChangeToken(value: 0))
        // changes(in:since:) stays public (Task 4 hydrator may read the store directly,
        // though the transport wraps it — keeping it public avoids sealing the door
        // on that access pattern before Task 4 decides).
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
    }

    // MARK: - ReplicaStore + ReplicaHydrator (the iOS replica read path)

    func testReplicaStoreAndHydratorSurface() async throws {
        let store = try ReplicaStore.inMemory()
        let payload = try RowPayloadCoder.payload(from: Row(["id": 1, "text": "surface"]))
        let record = CloudRecord(
            recordName: SliceKind.target.recordName(id: "1"),
            zone: .data,
            kind: SliceKind.target.rawValue,
            modifiedAt: Date(),
            payload: payload
        )
        let transport: any CloudSyncTransport = InMemoryCloudTransport()
        try await transport.save([record])

        let hydrator = ReplicaHydrator(transport: transport, store: store)
        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.deleted, 0)

        // Typed reads: exactly what the iOS list UIs call.
        let targets = try store.fetchAll(Target.self, kind: .target)
        XCTAssertEqual(targets.first?.text, "surface")
        XCTAssertEqual(store.corruptCount(), 0)
        XCTAssertNotNil(try store.storedToken())

        // reader is the ValueObservation entry point for the UI, and
        // fetchAll(_:kind:from:) is the overload the app's ReplicaObserver
        // calls inside its tracking closure (the closure's own db) — both must
        // be public for the app to build.
        let count = try await store.reader.read { db -> Int in
            _ = try store.fetchAll(Target.self, kind: .target, from: db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(count, 1)

        await hydrator.start(interval: .seconds(60))
        await hydrator.stop()
    }
}
