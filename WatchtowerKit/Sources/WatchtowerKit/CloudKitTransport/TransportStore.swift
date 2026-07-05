import Foundation
import GRDB

/// Persistence for the CloudKit adapter: an incoming change buffer (the
/// source of pull-shaped `changes(since:)` tokens — seqs in this store),
/// a pending-send queue, and the opaque CKSyncEngine state blob.
/// Pure GRDB — fully unit-testable without CloudKit.
public final class TransportStore: Sendable {
    private let queue: DatabaseQueue

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
            // events is append-only in Plan 2: compaction (dropping events older
            // than every consumer's floor token) is deliberately deferred — a
            // single-consumer desktop hub grows this slowly. Owner: Plan 3 revisits
            // when the mobile replica becomes a second consumer.
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
        try queue.read { db in
            // rowid survives ON CONFLICT DO UPDATE, so batches are ordered by
            // FIRST enqueue — a hot record cannot starve older pending sends.
            // Do not "fix" to latest-write ordering.
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending ORDER BY rowid LIMIT ?",
                arguments: [limit]
            )
            var saves: [CloudRecord] = []
            var deletes: [(name: String, zone: CloudZoneID)] = []
            for row in rows {
                guard let zone = CloudZoneID(rawValue: row["zone"]) else { continue }
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
            return (saves, deletes)
        }
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
}
