import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

/// Spy transport: forwards everything to InMemoryCloudTransport but ALSO
/// conforms to CompactingTransport, flipping a flag if compact is ever
/// invoked. Compact is off the CloudSyncTransport seam, so RelayProcessor
/// cannot call it directly — this spy catches a future regression where a
/// downcast (`transport as? CompactingTransport`) reintroduces per-cycle
/// relay compaction, which would silently disable server-side retention.
private actor CompactSpyTransport: CompactingTransport {
    private let inner = InMemoryCloudTransport()
    private(set) var compactCalled = false

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
        compactCalled = true
    }
}

/// Sweep-capable spy over a REAL TransportStore: `changes()` reads the same
/// buffer `sweepEvents` deletes from, so hygiene-vs-sweep ordering is
/// observable end-to-end. `save()` buffers own records immediately (InMemory
/// semantics); `delete()` records the name and appends a tombstone event,
/// like a CloudKit deletion fetched back.
private actor StoreBackedSweepTransport: SweepingTransport {
    private let store: TransportStore
    private(set) var deletedNames: [String] = []
    /// Names deleted before the first sweep ran — pins that hygiene's
    /// aged-record scan happens BEFORE the buffer sweep.
    private(set) var deletesBeforeFirstSweep: [String] = []
    private(set) var sweptCounts: [Int] = []

    init() throws {
        store = try TransportStore.inMemory()
    }

    /// Seeds fetched-shaped events directly (as if pulled from the server).
    func seed(_ records: [CloudRecord]) throws {
        try store.bufferChanged(records)
    }

    func save(_ records: [CloudRecord]) async throws {
        try store.bufferChanged(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        deletedNames += recordNames
        if sweptCounts.isEmpty { deletesBeforeFirstSweep += recordNames }
        try store.bufferDeleted(recordNames: recordNames, zone: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try store.changes(in: zone, since: token)
    }

    func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) async throws -> Int {
        let swept = try store.sweepEvents(in: zone, olderThan: cutoff, upTo: token)
        sweptCounts.append(swept)
        return swept
    }
}

final class RelayProcessorHygieneTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var transport: CompactSpyTransport!
    private var processor: RelayProcessor!
    private let fixedNow = Date(timeIntervalSince1970: 1_782_009_600)

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        transport = CompactSpyTransport()
        processor = RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: MockClaudeService()
        ) { [fixedNow] in fixedNow }
    }

    override func tearDownWithError() throws {
        processor = nil
        transport = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    /// Regression for the retention fix: processOnce must never compact the
    /// relay buffer, because hygiene's full-zone scan (`since: nil`) needs
    /// records to survive in the buffer for 7/30 days before it can find and
    /// delete them server-side. Records leave the token window within one poll
    /// cycle — if compact ran per cycle, hygiene would never see anything old.
    func testHygieneFindsAgedRecordAfterMultipleProcessOnceCycles() async throws {
        // Several processOnce cycles, each advancing the relay change token.
        // Enqueue a live action mid-way so the cycles do real work.
        try await dbPool.write { db in try TestDatabase.insertInboxItem(db) } // id 1
        let live = ActionRequestPayload(id: "live-1", kind: .inboxDismiss, entityID: "1", createdAt: fixedNow)
        try await transport.save([try CloudRecordFactory.record(for: live, modifiedAt: fixedNow)])
        for _ in 0..<5 {
            _ = try await processor.processOnce()
        }

        // Seed an 8-day-old PROCESSED (applied) action into the buffer, as if
        // it had been sitting in the relay zone aging since a week ago.
        let staleDate = fixedNow.addingTimeInterval(-8 * 86_400)
        var staleAction = ActionRequestPayload(id: "stale-1", kind: .inboxResolve, entityID: "99", createdAt: staleDate)
        staleAction.status = .applied
        let staleRecord = try CloudRecordFactory.record(for: staleAction, modifiedAt: staleDate)
        try await transport.save([staleRecord])

        // Hygiene runs immediately (no prior stamp in the fresh sidecar).
        try await processor.runHygieneIfDue()

        // Prior cycles must not have removed the history hygiene scans:
        // the aged record was found and deleted by hygiene itself.
        let remaining = try await transport.changes(in: .relay, since: nil).changed
        XCTAssertFalse(
            remaining.map(\.recordName).contains(staleRecord.recordName),
            "hygiene must find and delete the 8-day-old applied action from the retained buffer"
        )

        // And the processor never asked the transport to compact — even though
        // this transport conforms to CompactingTransport and would honor it.
        let compacted = await transport.compactCalled
        XCTAssertFalse(
            compacted,
            "RelayProcessor must never compact the relay buffer; hygiene's aged-record scan depends on full history"
        )
    }

    // MARK: - Buffer age sweep (SweepingTransport)

    /// Builds a processor over a sweep-capable transport with a mutable clock.
    private func makeSweepProcessor(
        transport: StoreBackedSweepTransport
    ) -> (RelayProcessor, OSAllocatedUnfairLock<Date>) {
        let clock = OSAllocatedUnfairLock<Date>(initialState: fixedNow)
        let processor = RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: MockClaudeService()
        ) { [clock] in clock.withLock { $0 } }
        return (processor, clock)
    }

    private func chunkRecord(messageID: String, age: TimeInterval) throws -> CloudRecord {
        let chunk = ChatChunkPayload(sessionID: "s", messageID: messageID, seq: 0, text: "old", done: true)
        return try CloudRecordFactory.record(for: chunk, modifiedAt: fixedNow.addingTimeInterval(-age))
    }

    /// Ordering pinned: the aged-record scan (server-side retention) must run
    /// BEFORE the buffer sweep. Had the sweep run first, the 35-day-old event
    /// would be gone from the `since: nil` scan and its server record would
    /// never be deleted.
    func testHygieneSweepsConsumedAgedEventsAfterServerDeletePass() async throws {
        let transport = try StoreBackedSweepTransport()
        let (processor, _) = makeSweepProcessor(transport: transport)

        let aged = try chunkRecord(messageID: "old-m", age: 35 * 86_400)
        let fresh = try chunkRecord(messageID: "new-m", age: 86_400)
        try await transport.seed([aged, fresh])
        // The processor has consumed both events (chunks pass through, the
        // token still advances) — they are below the stored relay token.
        _ = try await processor.processOnce()

        try await processor.runHygieneIfDue()

        let orderedDeletes = await transport.deletesBeforeFirstSweep
        XCTAssertTrue(
            orderedDeletes.contains(aged.recordName),
            "hygiene must server-delete the aged record BEFORE the sweep trims its buffer event"
        )
        let sweptCounts = await transport.sweptCounts
        XCTAssertEqual(sweptCounts, [1], "the sweep trims exactly the aged consumed event")

        let remaining = try await transport.changes(in: .relay, since: nil).changed.map(\.recordName)
        XCTAssertTrue(remaining.contains(fresh.recordName), "a within-window event survives the sweep")
        XCTAssertFalse(remaining.contains(aged.recordName))
    }

    /// The load-bearing sweep-vs-token interaction: a desktop that was off for
    /// weeks buffers a 35-day-old PENDING action on its first pull, with a seq
    /// ABOVE the stored token — and the relay loop runs hygiene before
    /// processOnce. The token-floored sweep must spare it so the action is
    /// still applied; once processed, the next hygiene pass reaps both the
    /// server record and the buffered event.
    func testSweepSparesUnconsumedAgedPendingActionUntilProcessed() async throws {
        try await dbPool.write { db in try TestDatabase.insertInboxItem(db) } // id 1
        let transport = try StoreBackedSweepTransport()
        let (processor, clock) = makeSweepProcessor(transport: transport)

        let staleDate = fixedNow.addingTimeInterval(-35 * 86_400)
        let action = ActionRequestPayload(id: "late-1", kind: .inboxDismiss, entityID: "1", createdAt: staleDate)
        let record = try CloudRecordFactory.record(for: action, modifiedAt: staleDate)
        try await transport.seed([record])

        // First relay-loop iteration after the long downtime: hygiene first.
        try await processor.runHygieneIfDue()

        let deletedEarly = await transport.deletedNames
        XCTAssertFalse(
            deletedEarly.contains(record.recordName),
            "the pending-action guard must spare the unprocessed action server-side"
        )
        let firstSweeps = await transport.sweptCounts
        XCTAssertEqual(firstSweeps, [0], "the sweep must not touch events above the stored token")

        // …so the processor still applies it and mobile hears the outcome.
        let applied = try await processor.processOnce()
        XCTAssertEqual(applied, 1, "the aged pending action must survive hygiene and be applied")

        // Eight days later (applied echo now beyond the 7-day action window):
        // hygiene reaps the server record and the sweep trims the consumed event.
        clock.withLock { $0 = fixedNow.addingTimeInterval(8 * 86_400) }
        try await processor.runHygieneIfDue()

        let deletedLate = await transport.deletedNames
        XCTAssertTrue(deletedLate.contains(record.recordName), "processed action is reaped once aged")
        let lastSwept = await transport.sweptCounts.last
        XCTAssertEqual(lastSwept, 1, "the consumed original event is swept once below the token")
    }
}
