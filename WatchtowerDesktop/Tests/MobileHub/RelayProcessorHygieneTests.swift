import GRDB
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
}
