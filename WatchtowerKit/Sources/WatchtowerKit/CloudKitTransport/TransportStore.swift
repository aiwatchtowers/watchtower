import Foundation
import GRDB
import os

/// Persistence for the CloudKit adapter: an incoming change buffer (the
/// source of pull-shaped `changes(since:)` tokens — seqs in this store),
/// a pending-send queue, and the opaque CKSyncEngine state blob.
/// Pure GRDB — fully unit-testable without CloudKit.
public final class TransportStore: Sendable {
    private let queue: DatabaseQueue
    private let logger = Logger(subsystem: "WatchtowerKit", category: "TransportStore")

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try createSchema()
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try createSchema()
    }

    public static func inMemory() throws -> TransportStore {
        try TransportStore(queue: DatabaseQueue())
    }

    private func createSchema() throws {
        try queue.write { db in
            // events is append-only. Compaction (dropping seq ≤ consumer floor)
            // is available via compactEvents(_:keepSince:) — called by a CompactingTransport
            // consumer (Plan 3 Task 4 hydrator). The relay zone retains full history
            // until hygiene has aged records out; see CompactingTransport.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    zone TEXT NOT NULL,
                    record_name TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT '',
                    modified_at REAL NOT NULL DEFAULT 0,
                    payload BLOB,
                    deleted INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS pending (
                    record_name TEXT NOT NULL,
                    zone TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT '',
                    modified_at REAL NOT NULL DEFAULT 0,
                    payload BLOB,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (record_name, zone)
                );
                CREATE TABLE IF NOT EXISTS engine_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    data BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS system_fields (
                    record_name TEXT NOT NULL,
                    zone TEXT NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (record_name, zone)
                );
                """)
        }
    }

    // MARK: - Pending sends

    public func enqueueSave(_ records: [CloudRecord]) throws {
        try queue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO pending (record_name, zone, kind, modified_at, payload, deleted)
                        VALUES (?, ?, ?, ?, ?, 0)
                        ON CONFLICT(record_name, zone) DO UPDATE SET
                            kind = excluded.kind,
                            modified_at = excluded.modified_at,
                            payload = excluded.payload,
                            deleted = 0
                        """,
                    arguments: [
                        record.recordName, record.zone.rawValue, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload
                    ]
                )
            }
        }
    }

    public func enqueueDelete(recordNames: [String], zone: CloudZoneID) throws {
        try queue.write { db in
            for name in recordNames {
                try db.execute(
                    sql: """
                        INSERT INTO pending (record_name, zone, deleted)
                        VALUES (?, ?, 1)
                        ON CONFLICT(record_name, zone) DO UPDATE SET
                            payload = NULL, deleted = 1
                        """,
                    arguments: [name, zone.rawValue]
                )
            }
        }
    }

    public func pendingBatch(limit: Int) throws -> (saves: [CloudRecord], deletes: [(name: String, zone: CloudZoneID)]) {
        // rowid survives ON CONFLICT DO UPDATE, so batches are ordered by
        // FIRST enqueue — a hot record cannot starve older pending sends.
        // Do not "fix" to latest-write ordering.
        let rows = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT rowid, * FROM pending ORDER BY rowid LIMIT ?",
                arguments: [limit]
            )
        }
        var saves: [CloudRecord] = []
        var deletes: [(name: String, zone: CloudZoneID)] = []
        var orphanRowIDs: [Int64] = []
        for row in rows {
            guard let zone = CloudZoneID(rawValue: row["zone"]) else {
                // A zone that no longer maps (corruption, a stale artefact of a
                // previous account) would loop forever on every nudge — evict it.
                orphanRowIDs.append(row["rowid"])
                continue
            }
            if (row["deleted"] as Int64? ?? 0) != 0 {
                deletes.append((name: row["record_name"], zone: zone))
            } else {
                saves.append(CloudRecord(
                    recordName: row["record_name"],
                    zone: zone,
                    kind: row["kind"],
                    modifiedAt: Date(timeIntervalSince1970: row["modified_at"] ?? 0),
                    payload: row["payload"] ?? Data()
                ))
            }
        }
        if !orphanRowIDs.isEmpty {
            try queue.write { db in
                for rowID in orphanRowIDs {
                    try db.execute(sql: "DELETE FROM pending WHERE rowid = ?", arguments: [rowID])
                }
            }
            logger.warning("evicted \(orphanRowIDs.count, privacy: .public) pending rows with an unmappable zone")
        }
        return (saves, deletes)
    }

    public func clearPending(
        saves: [(name: String, zone: CloudZoneID, sentModifiedAt: Date)],
        deletes: [(name: String, zone: CloudZoneID)]
    ) throws {
        try queue.write { db in
            for entry in saves {
                // Only clear if the pending row hasn't been superseded by a
                // newer local edit (modified_at > sentModifiedAt means a re-enqueue
                // already landed while this batch was in flight).
                try db.execute(
                    sql: """
                        DELETE FROM pending
                        WHERE record_name = ? AND zone = ? AND deleted = 0
                          AND modified_at <= ?
                        """,
                    arguments: [entry.name, entry.zone.rawValue,
                                entry.sentModifiedAt.timeIntervalSince1970]
                )
            }
            for entry in deletes {
                try db.execute(
                    sql: "DELETE FROM pending WHERE record_name = ? AND zone = ? AND deleted = 1",
                    arguments: [entry.name, entry.zone.rawValue]
                )
            }
        }
    }

    // MARK: - Incoming buffer

    public func bufferChanged(_ records: [CloudRecord]) throws {
        try queue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO events (zone, record_name, kind, modified_at, payload, deleted)
                        VALUES (?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        record.zone.rawValue, record.recordName, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload
                    ]
                )
            }
        }
    }

    public func bufferDeleted(recordNames: [String], zone: CloudZoneID) throws {
        try queue.write { db in
            for name in recordNames {
                try db.execute(
                    sql: "INSERT INTO events (zone, record_name, deleted) VALUES (?, ?, 1)",
                    arguments: [zone.rawValue, name]
                )
            }
        }
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) throws -> CloudChangeBatch {
        try queue.read { db in
            let floor = token?.value ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM events WHERE zone = ? AND seq > ? ORDER BY seq",
                arguments: [zone.rawValue, floor]
            )

            // Latest event per recordName wins, in first-seen order —
            // mirrors InMemoryCloudTransport (semantics frozen in Plan 1).
            var latest: [String: Row] = [:]
            var order: [String] = []
            var maxSeq = floor
            for row in rows {
                let name: String = row["record_name"]
                if latest[name] == nil { order.append(name) }
                latest[name] = row
                maxSeq = max(maxSeq, Int(row["seq"] as Int64? ?? 0))
            }

            var changed: [CloudRecord] = []
            var deleted: [String] = []
            for name in order {
                guard let row = latest[name] else { continue }
                if (row["deleted"] as Int64? ?? 0) != 0 {
                    deleted.append(name)
                } else {
                    changed.append(CloudRecord(
                        recordName: name,
                        zone: zone,
                        kind: row["kind"],
                        modifiedAt: Date(timeIntervalSince1970: row["modified_at"] ?? 0),
                        payload: row["payload"] ?? Data()
                    ))
                }
            }
            return CloudChangeBatch(changed: changed, deletedRecordNames: deleted, newToken: CloudChangeToken(value: maxSeq))
        }
    }

    // MARK: - CK system fields

    /// Archived CKRecord system fields (identity + server change tag) per
    /// (recordName, zone). Seeding outgoing saves from these is what lets a
    /// re-save of a server-known record carry the change tag instead of
    /// colliding with .serverRecordChanged forever.
    public func saveSystemFields(_ data: Data, recordName: String, zone: CloudZoneID) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO system_fields (record_name, zone, data)
                    VALUES (?, ?, ?)
                    ON CONFLICT(record_name, zone) DO UPDATE SET data = excluded.data
                    """,
                arguments: [recordName, zone.rawValue, data]
            )
        }
    }

    public func systemFields(recordName: String, zone: CloudZoneID) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT data FROM system_fields WHERE record_name = ? AND zone = ?",
                arguments: [recordName, zone.rawValue]
            )
        }
    }

    public func deleteSystemFields(recordNames: [String], zone: CloudZoneID) throws {
        try queue.write { db in
            for name in recordNames {
                try db.execute(
                    sql: "DELETE FROM system_fields WHERE record_name = ? AND zone = ?",
                    arguments: [name, zone.rawValue]
                )
            }
        }
    }

    // MARK: - Engine state

    public func saveEngineState(_ data: Data) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO engine_state (id, data) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                arguments: [data]
            )
        }
    }

    public func loadEngineState() throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM engine_state WHERE id = 1")
        }
    }

    // MARK: - Reset / retention / eviction

    /// Clears ALL adapter state in one transaction (schema stays). Called on
    /// a CloudKit account change: leaving stale system_fields behind would
    /// re-introduce the stale-change-tag wedge (a re-save of an old-account
    /// record carrying a change tag the new account's server never issued).
    public func wipe() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM events")
            try db.execute(sql: "DELETE FROM pending")
            try db.execute(sql: "DELETE FROM system_fields")
            try db.execute(sql: "DELETE FROM engine_state")
        }
    }

    /// Drops buffered events at or below a consumer's floor token for one zone.
    /// Safe because `changes(since:)` only ever reads `seq > token`, so a
    /// consumer sitting at `token` sees identical results before and after —
    /// the consumed prefix is dead weight. Owners call it with their own floor.
    public func compactEvents(in zone: CloudZoneID, keepSince token: CloudChangeToken) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM events WHERE zone = ? AND seq <= ?",
                arguments: [zone.rawValue, token.value]
            )
        }
    }

    /// Drops a zone's buffered events and archived system fields after a
    /// server-side zone deletion. Pending rows are intentionally kept: the
    /// transport's `saveZone` in `start()` and `handleFetchedDatabaseChanges`
    /// re-registers the zone as a pending database change, so the surviving
    /// pending rows re-send and land in a freshly created zone.
    public func evictZone(_ zone: CloudZoneID) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM events WHERE zone = ?", arguments: [zone.rawValue])
            try db.execute(sql: "DELETE FROM system_fields WHERE zone = ?", arguments: [zone.rawValue])
        }
    }

    #if DEBUG
    /// Test-only: inject a pending row with an arbitrary (possibly unmappable)
    /// zone string to exercise pendingBatch's orphan-eviction path.
    func injectRawPendingRow(recordName: String, zoneRaw: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO pending (record_name, zone, deleted) VALUES (?, ?, 0)",
                arguments: [recordName, zoneRaw]
            )
        }
    }
    #endif
}
