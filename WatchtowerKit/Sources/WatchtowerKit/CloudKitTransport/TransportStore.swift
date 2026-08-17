import Foundation
import GRDB
import os

/// Persistence for the CloudKit adapter: an incoming change buffer (the
/// source of pull-shaped `changes(since:)` tokens — seqs in this store),
/// a pending-send queue, and the opaque CKSyncEngine state blob.
/// Pure GRDB — fully unit-testable without CloudKit.
public final class TransportStore: Sendable {
    private let queue: DatabaseQueue
    /// Durable copies of fetched CKAsset files live here (next to the DB) —
    /// CloudKit's own staged asset files are temporary and may vanish before
    /// the buffered event is consumed. nil for in-memory stores (tests),
    /// which have no fetched assets to stash.
    private let assetsDirectory: URL?
    private let logger = Logger(subsystem: "WatchtowerKit", category: "TransportStore")

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        assetsDirectory = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("transport-assets", isDirectory: true)
        try createSchema()
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        assetsDirectory = nil
        try createSchema()
    }

    public static func inMemory() throws -> TransportStore {
        try TransportStore(queue: DatabaseQueue())
    }

    private func createSchema() throws {
        try queue.write { db in
            // events is append-only. Two retention primitives trim it:
            // compactEvents(_:keepSince:) drops seq ≤ consumer floor — called by a
            // CompactingTransport consumer (the Plan 3 replica hydrator, .data zone).
            // sweepEvents(in:olderThan:upTo:) drops consumed events past an age
            // cutoff — called by the desktop's daily relay hygiene, which needs the
            // .relay zone to retain history until its aged-record scan has seen a
            // record through the full 7/30-day windows (see SweepingTransport).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    zone TEXT NOT NULL,
                    record_name TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT '',
                    modified_at REAL NOT NULL DEFAULT 0,
                    payload BLOB,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    notify_level TEXT,
                    asset_path TEXT
                );
                CREATE TABLE IF NOT EXISTS pending (
                    record_name TEXT NOT NULL,
                    zone TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT '',
                    modified_at REAL NOT NULL DEFAULT 0,
                    payload BLOB,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    notify_level TEXT,
                    asset_path TEXT,
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
            // notify_level (Plan 6) and asset_path (phone recording uploads)
            // arrived after store files could already exist on disk.
            // CREATE TABLE IF NOT EXISTS cannot add a column, so patch older
            // tables in place.
            for table in ["events", "pending"] {
                let columns = try db.columns(in: table).map(\.name)
                for column in ["notify_level", "asset_path"] where !columns.contains(column) {
                    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) TEXT")
                }
            }
        }
    }

    // MARK: - Pending sends

    func enqueueSave(_ records: [CloudRecord]) throws {
        try queue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO pending
                            (record_name, zone, kind, modified_at, payload, deleted, notify_level, asset_path)
                        VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                        ON CONFLICT(record_name, zone) DO UPDATE SET
                            kind = excluded.kind,
                            modified_at = excluded.modified_at,
                            payload = excluded.payload,
                            deleted = 0,
                            notify_level = excluded.notify_level,
                            asset_path = excluded.asset_path
                        """,
                    arguments: [
                        record.recordName, record.zone.rawValue, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload,
                        record.notifyLevel, record.assetFileURL?.path
                    ]
                )
            }
        }
    }

    func enqueueDelete(recordNames: [String], zone: CloudZoneID) throws {
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

    func pendingBatch(limit: Int) throws -> (saves: [CloudRecord], deletes: [(name: String, zone: CloudZoneID)]) {
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
                    payload: row["payload"] ?? Data(),
                    notifyLevel: row["notify_level"],
                    assetFileURL: (row["asset_path"] as String?).map(URL.init(fileURLWithPath:))
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

    func clearPending(
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

    func bufferChanged(_ records: [CloudRecord]) throws {
        try queue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO events
                            (zone, record_name, kind, modified_at, payload, deleted, notify_level, asset_path)
                        VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                        """,
                    arguments: [
                        record.zone.rawValue, record.recordName, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload,
                        record.notifyLevel, record.assetFileURL?.path
                    ]
                )
            }
        }
    }

    func bufferDeleted(recordNames: [String], zone: CloudZoneID) throws {
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
                        payload: row["payload"] ?? Data(),
                        notifyLevel: row["notify_level"],
                        assetFileURL: (row["asset_path"] as String?).map(URL.init(fileURLWithPath:))
                    ))
                }
            }
            return CloudChangeBatch(changed: changed, deletedRecordNames: deleted, newToken: CloudChangeToken(value: maxSeq))
        }
    }

    // MARK: - Fetched-asset stash

    /// Copies a fetched CKAsset file into the store's durable asset
    /// directory, named after the record so a re-fetch overwrites rather
    /// than accumulates. Returns the stashed URL, or nil when there is
    /// nowhere to stash (in-memory store) or the copy failed — callers keep
    /// the original (temporary) URL in that case, best-effort. The consumer
    /// (the desktop hub) deletes the stashed file once ingested.
    func stashAsset(from url: URL, recordName: String) -> URL? {
        guard let assetsDirectory else { return nil }
        // Record names are `recupload-<uuid>` shaped, but sanitize anyway:
        // a path separator in a name must not escape the stash directory.
        let safeName = recordName.replacingOccurrences(of: "/", with: "_")
        let destination = assetsDirectory.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            logger.warning("""
                failed to stash fetched asset for \(recordName, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }

    // MARK: - CK system fields

    /// Archived CKRecord system fields (identity + server change tag) per
    /// (recordName, zone). Seeding outgoing saves from these is what lets a
    /// re-save of a server-known record carry the change tag instead of
    /// colliding with .serverRecordChanged forever.
    func saveSystemFields(_ data: Data, recordName: String, zone: CloudZoneID) throws {
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

    func systemFields(recordName: String, zone: CloudZoneID) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT data FROM system_fields WHERE record_name = ? AND zone = ?",
                arguments: [recordName, zone.rawValue]
            )
        }
    }

    func deleteSystemFields(recordNames: [String], zone: CloudZoneID) throws {
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

    func saveEngineState(_ data: Data) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO engine_state (id, data) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                arguments: [data]
            )
        }
    }

    func loadEngineState() throws -> Data? {
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

    /// Drops buffered events that are BOTH older than `cutoff` (by `modified_at`)
    /// AND at or below the consumer floor `token`. Returns the number of rows deleted.
    ///
    /// Why AGE-based and not purely token-based (the Plan 3 final-review argument):
    /// sweeping everything ≤ the consumer token is `compactEvents` — it deletes
    /// events the moment they are consumed, which would re-blind the relay
    /// hygiene's full-zone aged-record scan (`changes(since: nil)`) and silently
    /// disable server-side retention. An age cutoff with a margin past the longest
    /// hygiene window cannot: anything older than the cutoff has had a daily scan
    /// every day it was in-window.
    ///
    /// Why the `token` floor on top of age: an event's `modified_at` is the
    /// RECORD's timestamp, not the buffering time. A device that was offline past
    /// the cutoff window buffers old-modifiedAt records on its first pull, with
    /// seqs ABOVE its stored token — and the relay loop runs hygiene before
    /// processing. An unguarded age sweep would delete a still-pending mobile
    /// action the processor never consumed (and CKSyncEngine never redelivers
    /// fetched records), losing the action permanently. The floor makes the sweep
    /// touch only events every token consumer has already read, so it can never
    /// change what `changes(since: storedToken)` returns. Known liveness limit
    /// (pre-existing class): a persistently-throwing consumer loop never advances
    /// its stored token, freezing the floor — buffered-event growth returns for
    /// as long as that consumer is dead, and the first successful pass unfreezes
    /// the sweep.
    ///
    /// Deletion events (tombstones, `modified_at` = 0) fall below any real cutoff
    /// once consumed — intended, or hygiene's own server-side deletes would grow
    /// the buffer forever. Known bounded quirk: sweeping a record's tombstone
    /// while its younger-than-cutoff change event survives makes the next
    /// full-zone scan see the record as changed again, so hygiene re-issues an
    /// idempotent server delete daily until the change event ages out — worst
    /// case for the relay's actions, whose server lifetime (`actionMaxAge`) is
    /// far shorter than the zone's shared chat-length sweep cutoff, that is
    /// roughly `chatMaxAge − actionMaxAge` of daily no-op deletes per record.
    @discardableResult
    public func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) throws -> Int {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM events WHERE zone = ? AND modified_at < ? AND seq <= ?",
                arguments: [zone.rawValue, cutoff.timeIntervalSince1970, token.value]
            )
            return db.changesCount
        }
    }

    /// Drops a zone's buffered events and archived system fields after a
    /// server-side zone deletion. Pending rows are intentionally kept: the
    /// transport's `saveZone` in `start()` and `handleFetchedDatabaseChanges`
    /// re-registers the zone as a pending database change, so the surviving
    /// pending rows re-send and land in a freshly created zone.
    /// Internal: only the CloudKit adapter reacts to zone deletions.
    func evictZone(_ zone: CloudZoneID) throws {
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
