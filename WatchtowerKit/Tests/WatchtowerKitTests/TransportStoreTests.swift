import GRDB
import XCTest
@testable import WatchtowerKit

final class TransportStoreTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ name: String, zone: CloudZoneID = .data, payload: String = "{}") -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "target", modifiedAt: stamp, payload: Data(payload.utf8))
    }

    func testChangesMirrorInMemorySemantics() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1"), record("target-2")])
        let first = try store.changes(in: .data, since: nil)
        XCTAssertEqual(first.changed.map(\.recordName), ["target-1", "target-2"])

        try store.bufferChanged([record("target-3")])
        let second = try store.changes(in: .data, since: first.newToken)
        XCTAssertEqual(second.changed.map(\.recordName), ["target-3"])

        let third = try store.changes(in: .data, since: second.newToken)
        XCTAssertTrue(third.changed.isEmpty)
        XCTAssertEqual(third.newToken, second.newToken)
    }

    func testLatestEventWinsIncludingDeleteThenResave() throws {
        let store = try TransportStore.inMemory()
        try store.bufferDeleted(recordNames: ["target-1"], zone: .data)
        try store.bufferChanged([record("target-1", payload: "{\"v\":2}")])
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(batch.changed[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testZonesIsolatedInBuffer() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1", zone: .data)])
        try store.bufferChanged([record("action-1", zone: .relay)])
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["action-1"])
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["target-1"])
    }

    func testPendingUpsertLatestWriteWins() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1", payload: "{\"v\":1}")])
        try store.enqueueSave([record("target-1", payload: "{\"v\":2}")])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.count, 1)
        XCTAssertEqual(batch.saves[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletes.isEmpty)
    }

    func testDeleteReplacesPendingSaveForSameName() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1")])
        try store.enqueueDelete(recordNames: ["target-1"], zone: .data)
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertTrue(batch.saves.isEmpty)
        XCTAssertEqual(batch.deletes.map(\.name), ["target-1"])
    }

    func testClearPendingRemovesOnlyNamed() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1"), record("target-2")])
        try store.clearPending(saves: [(name: "target-1", zone: .data, sentModifiedAt: .distantFuture)], deletes: [])
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["target-2"])
    }

    func testClearPendingIsZoneScoped() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("shared-name", zone: .data)])
        try store.enqueueSave([record("shared-name", zone: .relay)])
        try store.clearPending(saves: [(name: "shared-name", zone: .data, sentModifiedAt: .distantFuture)], deletes: [])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.map(\.recordName), ["shared-name"])
        XCTAssertEqual(batch.saves[0].zone, .relay)
    }

    func testClearPendingKeepsNewerReEnqueuedSave() throws {
        let store = try TransportStore.inMemory()
        let v1Stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let v2Stamp = Date(timeIntervalSince1970: 1_700_000_100)
        let v1 = CloudRecord(recordName: "target-1", zone: .data, kind: "target", modifiedAt: v1Stamp, payload: Data("{\"v\":1}".utf8))
        try store.enqueueSave([v1])
        // v2 lands while v1 is in flight
        let v2 = CloudRecord(recordName: "target-1", zone: .data, kind: "target", modifiedAt: v2Stamp, payload: Data("{\"v\":2}".utf8))
        try store.enqueueSave([v2])
        // v1's send completes
        try store.clearPending(saves: [(name: "target-1", zone: .data, sentModifiedAt: v1Stamp)], deletes: [])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.map(\.recordName), ["target-1"], "newer pending save must survive the clear")
        XCTAssertEqual(batch.saves[0].payload, Data("{\"v\":2}".utf8))
    }

    func testInterleavedZoneWritesDoNotSkipOrDuplicate() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1", zone: .data)])      // seq 1
        let dataToken = try store.changes(in: .data, since: nil).newToken
        try store.bufferChanged([record("action-1", zone: .relay)])     // seq 2
        try store.bufferChanged([record("target-2", zone: .data)])      // seq 3

        let batch = try store.changes(in: .data, since: dataToken)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-2"])

        let after = try store.changes(in: .data, since: batch.newToken)
        XCTAssertTrue(after.changed.isEmpty)
        XCTAssertTrue(after.deletedRecordNames.isEmpty)
    }

    func testSystemFieldsRoundTrip() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))

        try store.saveSystemFields(Data("fields-v1".utf8), recordName: "target-1", zone: .data)
        XCTAssertEqual(try store.systemFields(recordName: "target-1", zone: .data), Data("fields-v1".utf8))

        // Re-save overwrites (server record changed → newer fields win).
        try store.saveSystemFields(Data("fields-v2".utf8), recordName: "target-1", zone: .data)
        XCTAssertEqual(try store.systemFields(recordName: "target-1", zone: .data), Data("fields-v2".utf8))

        try store.deleteSystemFields(recordNames: ["target-1"], zone: .data)
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))
    }

    func testSystemFieldsAreZoneScoped() throws {
        let store = try TransportStore.inMemory()
        try store.saveSystemFields(Data("data-zone".utf8), recordName: "shared-name", zone: .data)
        try store.saveSystemFields(Data("relay-zone".utf8), recordName: "shared-name", zone: .relay)
        XCTAssertEqual(try store.systemFields(recordName: "shared-name", zone: .data), Data("data-zone".utf8))
        XCTAssertEqual(try store.systemFields(recordName: "shared-name", zone: .relay), Data("relay-zone".utf8))

        try store.deleteSystemFields(recordNames: ["shared-name"], zone: .data)
        XCTAssertNil(try store.systemFields(recordName: "shared-name", zone: .data))
        XCTAssertEqual(try store.systemFields(recordName: "shared-name", zone: .relay), Data("relay-zone".utf8))
    }

    func testDeleteSystemFieldsRemovesOnlyNamed() throws {
        let store = try TransportStore.inMemory()
        try store.saveSystemFields(Data("a".utf8), recordName: "target-1", zone: .data)
        try store.saveSystemFields(Data("b".utf8), recordName: "target-2", zone: .data)
        try store.deleteSystemFields(recordNames: ["target-1", "never-saved"], zone: .data)
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data))
        XCTAssertEqual(try store.systemFields(recordName: "target-2", zone: .data), Data("b".utf8))
    }

    func testEngineStateRoundTrip() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(try store.loadEngineState())
        try store.saveEngineState(Data("state-blob".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("state-blob".utf8))
        try store.saveEngineState(Data("state-blob-2".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("state-blob-2".utf8))
    }

    // MARK: - wipe (account change)

    func testWipeClearsAllFourTables() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1")])
        try store.enqueueSave([record("target-2")])
        try store.saveSystemFields(Data("fields".utf8), recordName: "target-1", zone: .data)
        try store.saveEngineState(Data("state".utf8))

        try store.wipe()

        XCTAssertTrue(try store.changes(in: .data, since: nil).changed.isEmpty, "events cleared")
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty, "pending cleared")
        XCTAssertNil(try store.systemFields(recordName: "target-1", zone: .data), "system_fields cleared")
        XCTAssertNil(try store.loadEngineState(), "engine_state cleared")

        // Schema survives — the store is usable immediately after a wipe.
        try store.bufferChanged([record("target-3")])
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["target-3"])
    }

    // MARK: - compactEvents (retention)

    func testCompactEventsPreservesChangesForConsumerAtToken() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1"), record("target-2")]) // seq 1, 2
        let token = try store.changes(in: .data, since: nil).newToken       // consumer floor
        try store.bufferChanged([record("target-3")])                       // seq 3

        let before = try store.changes(in: .data, since: token)
        try store.compactEvents(in: .data, keepSince: token)
        let after = try store.changes(in: .data, since: token)

        // A consumer at its stored token sees identical results before/after.
        XCTAssertEqual(before.changed.map(\.recordName), after.changed.map(\.recordName))
        XCTAssertEqual(before.newToken, after.newToken)
        XCTAssertEqual(after.changed.map(\.recordName), ["target-3"])

        // The consumed events (<= floor) are physically gone from the buffer.
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["target-3"])
    }

    func testCompactEventsIsZoneScoped() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("data-1", zone: .data)])   // seq 1
        try store.bufferChanged([record("relay-1", zone: .relay)]) // seq 2

        // Compact the data zone past every seq — the relay buffer is untouched.
        try store.compactEvents(in: .data, keepSince: CloudChangeToken(value: 100))

        XCTAssertTrue(try store.changes(in: .data, since: nil).changed.isEmpty)
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["relay-1"])
    }

    // MARK: - sweepEvents (age-based retention)

    func testSweepEventsDeletesAgedConsumedEventsAndKeepsFresh() throws {
        let store = try TransportStore.inMemory()
        let now = Date()
        let aged = CloudRecord(
            recordName: "chunk-old", zone: .relay, kind: "chat_chunk",
            modifiedAt: now.addingTimeInterval(-35 * 86_400), payload: Data("{}".utf8)
        )
        let fresh = CloudRecord(
            recordName: "chunk-new", zone: .relay, kind: "chat_chunk",
            modifiedAt: now.addingTimeInterval(-60), payload: Data("{}".utf8)
        )
        try store.bufferChanged([aged, fresh])
        // Consumer has read everything (floor = max seq).
        let floor = try store.changes(in: .relay, since: nil).newToken

        let cutoff = now.addingTimeInterval(-31 * 86_400)
        let swept = try store.sweepEvents(in: .relay, olderThan: cutoff, upTo: floor)

        XCTAssertEqual(swept, 1, "exactly the aged event row is deleted")
        let names = try store.changes(in: .relay, since: nil).changed.map(\.recordName)
        XCTAssertEqual(names, ["chunk-new"], "within-window event must survive the sweep")
    }

    func testSweepEventsSparesUnconsumedEventsRegardlessOfAge() throws {
        // A desktop that was off for weeks buffers old-modifiedAt records on its
        // first pull; their seqs sit ABOVE the stored relay token. The sweep must
        // never delete them — the processor still has to consume them.
        let store = try TransportStore.inMemory()
        let now = Date()
        let pendingAction = CloudRecord(
            recordName: "action-old", zone: .relay, kind: "action",
            modifiedAt: now.addingTimeInterval(-35 * 86_400), payload: Data("{}".utf8)
        )
        try store.bufferChanged([pendingAction])

        // Consumer floor is 0 — nothing consumed yet.
        let swept = try store.sweepEvents(
            in: .relay, olderThan: now.addingTimeInterval(-31 * 86_400), upTo: CloudChangeToken(value: 0)
        )

        XCTAssertEqual(swept, 0)
        XCTAssertEqual(
            try store.changes(in: .relay, since: nil).changed.map(\.recordName),
            ["action-old"],
            "an unconsumed event survives the sweep regardless of age"
        )
    }

    func testSweepEventsIsZoneScoped() throws {
        let store = try TransportStore.inMemory()
        let old = Date(timeIntervalSince1970: 1)
        try store.bufferChanged([
            CloudRecord(recordName: "data-old", zone: .data, kind: "target", modifiedAt: old, payload: Data()),
            CloudRecord(recordName: "relay-old", zone: .relay, kind: "action", modifiedAt: old, payload: Data())
        ])
        let floor = CloudChangeToken(value: 100)

        _ = try store.sweepEvents(in: .relay, olderThan: Date(), upTo: floor)

        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["data-old"])
        XCTAssertTrue(try store.changes(in: .relay, since: nil).changed.isEmpty)
    }

    func testSweepEventsDeletesConsumedTombstones() throws {
        // Deletion events carry modified_at = 0, so any cutoff covers them once
        // they are below the consumer floor — hygiene's own server-side deletes
        // must not accumulate tombstone events forever.
        let store = try TransportStore.inMemory()
        try store.bufferDeleted(recordNames: ["action-gone"], zone: .relay)
        let floor = try store.changes(in: .relay, since: nil).newToken

        let swept = try store.sweepEvents(
            in: .relay, olderThan: Date().addingTimeInterval(-31 * 86_400), upTo: floor
        )

        XCTAssertEqual(swept, 1)
        let batch = try store.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    // MARK: - evictZone (server-side zone deletion)

    func testEvictZoneDropsEventsAndSystemFieldsButKeepsPending() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("data-1", zone: .data)])
        try store.saveSystemFields(Data("f".utf8), recordName: "data-1", zone: .data)
        try store.enqueueSave([record("data-1", zone: .data)])
        // Relay zone must survive an eviction of the data zone.
        try store.bufferChanged([record("relay-1", zone: .relay)])
        try store.saveSystemFields(Data("r".utf8), recordName: "relay-1", zone: .relay)

        try store.evictZone(.data)

        XCTAssertTrue(try store.changes(in: .data, since: nil).changed.isEmpty, "buffered events dropped")
        XCTAssertNil(try store.systemFields(recordName: "data-1", zone: .data), "system fields dropped")
        // Pending survives: it re-creates the zone via zone-setup on the next send.
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["data-1"],
                       "pending rows survive zone eviction")
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["relay-1"])
        XCTAssertEqual(try store.systemFields(recordName: "relay-1", zone: .relay), Data("r".utf8))
    }

    func testPendingBatchEvictsUnmappableZoneRows() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("keep-1", zone: .data)])
        // Inject a row whose zone no longer maps to a CloudZoneID (corruption
        // / stale account artefact). pendingBatch must evict it, not loop on it.
        try store.injectRawPendingRow(recordName: "orphan-1", zoneRaw: "GhostZone")

        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.map(\.recordName), ["keep-1"])
        // A second read confirms the orphan was physically removed.
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["keep-1"])
    }

    // MARK: - notifyLevel (Plan 6 Decision 3)

    func testNotifyLevelSurvivesPendingQueueAndEventBuffer() throws {
        let store = try TransportStore.inMemory()
        let tagged = CloudRecord(
            recordName: "inbox_item-1", zone: .data, kind: "inbox_item",
            modifiedAt: stamp, payload: Data("{}".utf8), notifyLevel: "urgent"
        )

        try store.enqueueSave([tagged, record("target-1")])
        let pending = try store.pendingBatch(limit: 10)
        XCTAssertEqual(pending.saves.map(\.notifyLevel), ["urgent", nil])

        try store.bufferChanged([tagged, record("target-1")])
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.notifyLevel), ["urgent", nil])
    }

    func testLegacyStoreFileGainsNotifyLevelColumn() throws {
        // A store created before Plan 6 has no notify_level column.
        // CREATE TABLE IF NOT EXISTS cannot add it, so opening the store must
        // migrate the tables in place — otherwise every INSERT fails forever.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("transport.sqlite").path

        // The exact pre-Plan-6 events/pending schema.
        do {
            let legacy = try DatabaseQueue(path: path)
            try legacy.write { db in
                try db.execute(sql: """
                    CREATE TABLE events (
                        seq INTEGER PRIMARY KEY AUTOINCREMENT,
                        zone TEXT NOT NULL,
                        record_name TEXT NOT NULL,
                        kind TEXT NOT NULL DEFAULT '',
                        modified_at REAL NOT NULL DEFAULT 0,
                        payload BLOB,
                        deleted INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE TABLE pending (
                        record_name TEXT NOT NULL,
                        zone TEXT NOT NULL,
                        kind TEXT NOT NULL DEFAULT '',
                        modified_at REAL NOT NULL DEFAULT 0,
                        payload BLOB,
                        deleted INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY (record_name, zone)
                    );
                    INSERT INTO events (zone, record_name, kind, modified_at, payload, deleted)
                    VALUES ('DataZone', 'target-1', 'target', 1700000000, X'7B7D', 0);
                    """)
            }
        }

        let store = try TransportStore(path: path)
        // Pre-existing rows read back with nil notifyLevel.
        let legacyBatch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(legacyBatch.changed.map(\.recordName), ["target-1"])
        XCTAssertNil(legacyBatch.changed[0].notifyLevel)

        // New tagged writes work on the migrated tables.
        let tagged = CloudRecord(
            recordName: "briefing-1", zone: .data, kind: "briefing",
            modifiedAt: stamp, payload: Data("{}".utf8), notifyLevel: "briefing"
        )
        try store.bufferChanged([tagged])
        try store.enqueueSave([tagged])
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.last?.notifyLevel, "briefing")
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.notifyLevel), ["briefing"])
    }
}
