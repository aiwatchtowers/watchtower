import CryptoKit
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
        // Launch pass: stash files an earlier run leaked (before the
        // eviction/wipe sweeps existed, or a crash between a buffer and its
        // compaction) are unreferenced by any row now.
        sweepUnreferencedStash()
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        assetsDirectory = nil
        try createSchema()
    }

    /// The fetched-asset stash directory (`transport-assets/` next to the
    /// database); nil for an in-memory store. The phone sets its file
    /// protection class (mobile E2E D8); the store creates it on demand.
    public var stashDirectory: URL? { assetsDirectory }

    public static func inMemory() throws -> TransportStore {
        try TransportStore(queue: DatabaseQueue())
    }

    private func createSchema() throws {
        try queue.write { db in
            // events is append-only. Two retention primitives trim it:
            // compactEvents(_:keepSince:) drops seq ≤ consumer floor — called by a
            // CompactingTransport consumer (the phone: the replica hydrator for
            // .data, RelayFeed for .relay).
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
                    asset_path TEXT,
                    creator TEXT,
                    server_modified_at REAL
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
                CREATE TABLE IF NOT EXISTS poll_tokens (
                    zone TEXT PRIMARY KEY,
                    token BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS scope (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    kind TEXT NOT NULL CHECK (kind IN ('private', 'shared')),
                    owner_name TEXT
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
            // creator (the hub's device gate) is fetched metadata: events only.
            if try !db.columns(in: "events").contains(where: { $0.name == "creator" }) {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN creator TEXT")
            }
            // server_modified_at (target 168, relay hygiene's clock) is fetched metadata too: events only.
            if try !db.columns(in: "events").contains(where: { $0.name == "server_modified_at" }) {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN server_modified_at REAL")
            }
            // hub_id (multi-hub spec §4.4): the hub this store's state belongs to.
            if try !db.columns(in: "scope").contains(where: { $0.name == "hub_id" }) {
                try db.execute(sql: "ALTER TABLE scope ADD COLUMN hub_id TEXT")
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
        var saves: [CloudRecord] = []
        var deletes: [(name: String, zone: CloudZoneID)] = []
        for (row, zone) in try pendingRows(columns: "*", limit: limit) {
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
        return (saves, deletes)
    }

    /// The identities of `pendingBatch(limit:)`'s rows — same order, same
    /// limit, same orphan eviction — without reading payload BLOBs. For the
    /// engine nudge, which schedules record IDs only; the engine reads the
    /// records themselves later through `pendingBatch`.
    func pendingNames(limit: Int) throws -> (
        saves: [(name: String, zone: CloudZoneID)],
        deletes: [(name: String, zone: CloudZoneID)]
    ) {
        var saves: [(name: String, zone: CloudZoneID)] = []
        var deletes: [(name: String, zone: CloudZoneID)] = []
        for (row, zone) in try pendingRows(columns: "record_name, zone, deleted", limit: limit) {
            let entry = (name: row["record_name"] as String, zone: zone)
            if (row["deleted"] as Int64? ?? 0) != 0 {
                deletes.append(entry)
            } else {
                saves.append(entry)
            }
        }
        return (saves, deletes)
    }

    /// The first `limit` pending rows (`columns`, which must include `zone`,
    /// plus rowid) with their mapped zone. Rows whose zone no longer maps are
    /// evicted.
    private func pendingRows(columns: String, limit: Int) throws -> [(row: Row, zone: CloudZoneID)] {
        // rowid survives ON CONFLICT DO UPDATE, so batches are ordered by
        // FIRST enqueue — a hot record cannot starve older pending sends.
        // Do not "fix" to latest-write ordering.
        let rows = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT rowid, \(columns) FROM pending ORDER BY rowid LIMIT ?",
                arguments: [limit]
            )
        }
        var mapped: [(row: Row, zone: CloudZoneID)] = []
        var orphanRowIDs: [Int64] = []
        for row in rows {
            guard let zone = CloudZoneID(rawValue: row["zone"]) else {
                // A zone that no longer maps (corruption, a stale artefact of a
                // previous account) would loop forever on every nudge — evict it.
                orphanRowIDs.append(row["rowid"])
                continue
            }
            mapped.append((row: row, zone: zone))
        }
        if !orphanRowIDs.isEmpty {
            try queue.write { db in
                for rowID in orphanRowIDs {
                    try db.execute(sql: "DELETE FROM pending WHERE rowid = ?", arguments: [rowID])
                }
            }
            logger.warning("evicted \(orphanRowIDs.count, privacy: .public) pending rows with an unmappable zone")
        }
        return mapped
    }

    /// Removes a record from the send queue whatever its stamp: the
    /// transport gives up on a record CloudKit rejects even on its own
    /// (`.limitExceeded` on a one-record batch), instead of retrying forever.
    /// The row goes whatever it holds: if the record was re-queued for
    /// deletion after the failed send, that delete is dropped too. Harmless
    /// for a record CloudKit refused to store.
    func dropPending(recordName: String, zone: CloudZoneID) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM pending WHERE record_name = ? AND zone = ?",
                arguments: [recordName, zone.rawValue]
            )
        }
    }

    /// Whether `recordName` in `zone` still waits in the send queue (a
    /// save or a delete CloudKit has not acknowledged yet). The phone's
    /// unlink reads it to wait, bounded, for its `unlinked` record to go.
    public func isPending(recordName: String, zone: CloudZoneID) throws -> Bool {
        try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM pending WHERE record_name = ? AND zone = ?)",
                arguments: [recordName, zone.rawValue]
            ) ?? false
        }
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
                            (zone, record_name, kind, modified_at, payload, deleted, notify_level, asset_path, creator,
                             server_modified_at)
                        VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                        """,
                    arguments: [
                        record.zone.rawValue, record.recordName, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload,
                        record.notifyLevel, record.assetFileURL?.path, record.creatorUserRecordName,
                        record.serverModifiedAt?.timeIntervalSince1970
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
                        assetFileURL: (row["asset_path"] as String?).map(URL.init(fileURLWithPath:)),
                        creatorUserRecordName: row["creator"],
                        serverModifiedAt: (row["server_modified_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                    ))
                }
            }
            return CloudChangeBatch(changed: changed, deletedRecordNames: deleted, newToken: CloudChangeToken(value: maxSeq))
        }
    }

    // MARK: - Fetched-asset stash

    /// The largest fetched asset the store stashes: a phone recording at the
    /// uploader's cap, sealed (the largest asset any record legitimately
    /// carries; a meeting transcript's is smaller).
    public static let maximumStashBytes = RecordingUploader.maximumSealedAssetBytes

    /// Copies a fetched CKAsset file into the store's durable asset
    /// directory, named after the record so a re-fetch overwrites rather
    /// than accumulates. Returns the stashed URL, or nil when there is
    /// nowhere to stash (in-memory store), the file is over `maxBytes` or
    /// the copy failed — callers keep the original (temporary) URL in that
    /// case, best-effort. A relay upload's consumer (the desktop hub)
    /// deletes the stashed file once ingested; a data-zone stash goes at
    /// `compactEvents(in: .data, …)`.
    ///
    /// The record name is server-supplied and unauthenticated here (the
    /// stash runs before anything is opened), so the file name is its
    /// SHA-256 with the zone, in hex: never a path of the sender's choosing.
    func stashAsset(
        from url: URL, recordName: String, zone: CloudZoneID, maxBytes: Int64 = TransportStore.maximumStashBytes
    ) -> URL? {
        guard let assetsDirectory else { return nil }
        let destination = assetsDirectory.appendingPathComponent(Self.stashFileName(recordName: recordName, zone: zone))
        guard destination.deletingLastPathComponent().standardizedFileURL == assetsDirectory.standardizedFileURL else {
            logger.error("stash path for \(recordName, privacy: .public) left the stash directory: not stashed")
            return nil
        }
        do {
            // An unreadable size is refused like an oversized one (fail closed).
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard let size, size <= maxBytes else {
                let shown = size.map { "\($0) bytes" } ?? "an unreadable size"
                logger.warning("fetched asset for \(recordName, privacy: .public) has \(shown, privacy: .public): not stashed")
                return nil
            }
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

    /// The stash file name of a record: hex SHA-256 of zone and name.
    static func stashFileName(recordName: String, zone: CloudZoneID) -> String {
        let digest = SHA256.hash(data: Data("\(zone.rawValue)\u{0}\(recordName)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    // MARK: - Poll change tokens

    /// The archived server change token of the transport's own zone poll
    /// (`CloudKitTransport.pull()`), per zone; separate from the engine's.
    func pollToken(zone: CloudZoneID) throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT token FROM poll_tokens WHERE zone = ?", arguments: [zone.rawValue])
        }
    }

    /// nil forgets the zone's token: the next poll starts from the beginning.
    func setPollToken(_ token: Data?, zone: CloudZoneID) throws {
        try queue.write { db in
            if let token {
                try db.execute(
                    sql: """
                        INSERT INTO poll_tokens (zone, token) VALUES (?, ?)
                        ON CONFLICT(zone) DO UPDATE SET token = excluded.token
                        """,
                    arguments: [zone.rawValue, token]
                )
            } else {
                try db.execute(sql: "DELETE FROM poll_tokens WHERE zone = ?", arguments: [zone.rawValue])
            }
        }
    }

    // MARK: - Database scope

    /// The scope this store's state belongs to; nil for a store that never
    /// recorded one (every store created before scopes existed was private).
    public func storedScope() throws -> CloudDatabaseScope? {
        try queue.read { db in try Self.readBinding(db)?.scope }
    }

    /// The hub this store's state belongs to; nil for a store bound to no
    /// hub (every store of the single-hub build).
    func storedHubID() throws -> String? {
        try queue.read { db in try Self.readBinding(db)?.hubID }
    }

    func saveScope(_ scope: CloudDatabaseScope, hubID: String) throws {
        try queue.write { db in try Self.writeScope(scope, hubID: hubID, db) }
    }

    /// Binds the store to `scope` and `hubID` (multi-hub spec §4.4). Engine
    /// state, system fields and buffered events of another database or
    /// another hub mean nothing here — archived system fields even name the
    /// old zone — so a store bound to anything else, or to no hub (every
    /// store of the single-hub build), is wiped first. Returns whether it
    /// held state to wipe: a brand-new store with no binding and no state
    /// returns false. `CloudKitTransport.start()` calls it; public so the
    /// phone's tests check a moved store as the start will.
    @discardableResult
    public func adoptScope(_ scope: CloudDatabaseScope, hubID: String) throws -> Bool {
        let wiped = try queue.write { db in
            let stored = try Self.readBinding(db)
            var wipe = stored?.scope != scope || stored?.hubID != hubID
            if stored == nil { wipe = try Self.holdsState(db) }
            if wipe { try Self.wipeState(db) }
            try Self.writeScope(scope, hubID: hubID, db)
            return wipe
        }
        if wiped { sweepUnreferencedStash() }
        return wiped
    }

    private static func readBinding(_ db: Database) throws -> (scope: CloudDatabaseScope, hubID: String?)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT kind, owner_name, hub_id FROM scope WHERE id = 1") else {
            return nil
        }
        let scope: CloudDatabaseScope
        switch row["kind"] as String {
        case "shared":
            scope = .shared(ownerName: row["owner_name"] ?? "")
        default:
            scope = .private
        }
        return (scope, row["hub_id"])
    }

    private static func writeScope(_ scope: CloudDatabaseScope, hubID: String, _ db: Database) throws {
        let kind: String
        let ownerName: String?
        switch scope {
        case .private: (kind, ownerName) = ("private", nil)
        case .shared(let name): (kind, ownerName) = ("shared", name)
        }
        try db.execute(
            sql: """
                INSERT INTO scope (id, kind, owner_name, hub_id) VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, owner_name = excluded.owner_name, hub_id = excluded.hub_id
                """,
            arguments: [kind, ownerName, hubID]
        )
    }

    /// Closes the database for good, before its files are deleted (the
    /// phone's hub removal); later calls throw. Closing again does nothing.
    public func close() throws {
        try queue.close()
    }

    // MARK: - Reset / retention / eviction

    /// Clears ALL adapter state in one transaction (schema stays). Called on
    /// a CloudKit account change: leaving stale system_fields behind would
    /// re-introduce the stale-change-tag wedge (a re-save of an old-account
    /// record carrying a change tag the new account's server never issued).
    /// The recorded scope and hub stay: they are link configuration, not
    /// account state.
    public func wipe() throws {
        try queue.write { db in try Self.wipeState(db) }
        sweepUnreferencedStash()
    }

    private static func holdsState(_ db: Database) throws -> Bool {
        try ["events", "pending", "system_fields", "engine_state", "poll_tokens"].contains { table in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table))") ?? false
        }
    }

    private static func wipeState(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM events")
        try db.execute(sql: "DELETE FROM pending")
        try db.execute(sql: "DELETE FROM system_fields")
        try db.execute(sql: "DELETE FROM engine_state")
        try db.execute(sql: "DELETE FROM poll_tokens")
    }

    /// Drops buffered events at or below a consumer's floor token for one zone.
    /// Safe because `changes(since:)` only ever reads `seq > token`, so a
    /// consumer sitting at `token` sees identical results before and after —
    /// the consumed prefix is dead weight. Owners call it with their own floor.
    ///
    /// Data zone: the consumer (the phone's replica) has copied the assets
    /// of the compacted events, so their stashed files go too — except a
    /// path a remaining (newer) event still references: the stash is named
    /// after the record, so a re-fetch after the batch was read overwrites
    /// the same file. Deleted records are covered: their earlier change
    /// events are compacted. Only files inside the stash directory are
    /// removed. Runs on the transport actor, so no fetch interleaves.
    ///
    /// Relay zone: the unreferenced stash is swept after the delete.
    public func compactEvents(in zone: CloudZoneID, keepSince token: CloudChangeToken) throws {
        let consumed = try queue.write { db -> [String] in
            var consumed: [String] = []
            if zone == .data {
                consumed = try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT asset_path FROM events
                        WHERE zone = ? AND seq <= ? AND asset_path IS NOT NULL
                          AND asset_path NOT IN (
                              SELECT asset_path FROM events
                              WHERE zone = ? AND seq > ? AND asset_path IS NOT NULL
                          )
                        """,
                    arguments: [zone.rawValue, token.value, zone.rawValue, token.value]
                )
            }
            try db.execute(
                sql: "DELETE FROM events WHERE zone = ? AND seq <= ?",
                arguments: [zone.rawValue, token.value]
            )
            return consumed
        }
        removeStashedFiles(atPaths: consumed)
        // Relay zone: only the phone compacts it (RelayFeed; the hub sweeps
        // its relay buffer by age instead), and nothing there reads a relay
        // stash after routing — so an own upload reflecting back with its
        // audio-sized asset goes now, not at the next launch's sweep.
        if zone == .relay { sweepUnreferencedStash() }
    }

    /// Removes the files among `paths` that live in the stash directory.
    private func removeStashedFiles(atPaths paths: [String]) {
        guard let stash = assetsDirectory?.standardizedFileURL else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL == stash,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.warning("consumed stash not removed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Drops buffered events that are BOTH older than `cutoff` (by the server's
    /// `server_modified_at`, else the writer's `modified_at` for an event buffered
    /// before it was kept) AND at or below the consumer floor `token`. Returns the
    /// number of rows deleted.
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
                sql: "DELETE FROM events WHERE zone = ? AND COALESCE(server_modified_at, modified_at) < ? AND seq <= ?",
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
            try db.execute(sql: "DELETE FROM poll_tokens WHERE zone = ?", arguments: [zone.rawValue])
        }
        // The evicted events took their stash references with them.
        sweepUnreferencedStash()
    }

    /// Removes every file in the stash directory that no buffered event and
    /// no pending row references — the stash's only owners. Runs at open (a
    /// launch sweep of earlier leaks), after `evictZone`, after a wipe and
    /// after a relay-zone compaction.
    /// Callers other than `init` run on the transport actor, whose fetch
    /// path stashes and buffers with no suspension in between, so a fresh
    /// stash is always referenced by the time a sweep can look. Best-effort:
    /// a missing directory is nothing to sweep, other failures are logged.
    func sweepUnreferencedStash() {
        guard let stash = assetsDirectory?.standardizedFileURL else { return }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: stash, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            logger.warning("stash sweep could not list the stash: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !files.isEmpty else { return }
        let referenced: Set<String>
        do {
            referenced = try queue.read { db in
                let paths = try String.fetchAll(db, sql: """
                    SELECT asset_path FROM events WHERE asset_path IS NOT NULL
                    UNION SELECT asset_path FROM pending WHERE asset_path IS NOT NULL
                    """)
                return Set(paths.map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().standardizedFileURL == stash }
                    .map(\.lastPathComponent))
            }
        } catch {
            // Without the references every file looks orphaned: keep them all.
            logger.warning("stash sweep could not read references: \(error.localizedDescription, privacy: .public)")
            return
        }
        for file in files where !referenced.contains(file.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.warning("unreferenced stash not removed: \(error.localizedDescription, privacy: .public)")
            }
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
