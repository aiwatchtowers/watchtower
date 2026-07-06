import Foundation
import GRDB

/// Persists per-record payload hashes so the hub can diff local DB rows
/// against what was last pushed to CloudKit without re-reading the full payload.
/// Mirrors the TransportStore GRDB pattern: DatabaseQueue + `CREATE TABLE IF NOT EXISTS`.
final class HubSyncState: Sendable {
    private let queue: DatabaseQueue

    init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try createSchema()
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try createSchema()
    }

    static func inMemory() throws -> HubSyncState {
        try HubSyncState(queue: DatabaseQueue())
    }

    private func createSchema() throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS slice_state (
                    record_name TEXT PRIMARY KEY,
                    payload_hash TEXT NOT NULL,
                    pushed_at REAL NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS hub_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS relay_processed (
                    record_name TEXT PRIMARY KEY,
                    processed_at REAL NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS chat_sessions (
                    mobile_session_id TEXT PRIMARY KEY,
                    cli_session_id TEXT
                );
                """)
        }
    }

    // MARK: - Hash queries

    /// Returns a recordName → payloadHash map for all records of the given kind.
    /// Filtered by `record_name LIKE '<kind.rawValue>-%'`.
    func hashes(forKind kind: SliceKind) throws -> [String: String] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT record_name, payload_hash FROM slice_state WHERE record_name LIKE ? ESCAPE '\\'",
                arguments: [kind.rawValue.replacingOccurrences(of: "_", with: "\\_") + "-%"]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["record_name"] as String, $0["payload_hash"] as String) })
        }
    }

    func setHash(_ hash: String, for recordName: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO slice_state (record_name, payload_hash, pushed_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        payload_hash = excluded.payload_hash,
                        pushed_at = excluded.pushed_at
                    """,
                arguments: [recordName, hash, Date().timeIntervalSince1970]
            )
        }
    }

    func removeHashes(_ recordNames: [String]) throws {
        guard !recordNames.isEmpty else { return }
        try queue.write { db in
            for name in recordNames {
                try db.execute(
                    sql: "DELETE FROM slice_state WHERE record_name = ?",
                    arguments: [name]
                )
            }
        }
    }

    // MARK: - Hub meta (relay change token, …)

    func metaValue(forKey key: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [key])
        }
    }

    func setMetaValue(_ value: String, forKey key: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hub_meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }

    // MARK: - Chat session mapping (mobile session → CLI session)

    func cliSessionID(forMobileSession mobileSessionID: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT cli_session_id FROM chat_sessions WHERE mobile_session_id = ?",
                arguments: [mobileSessionID]
            )
        }
    }

    func setCLISessionID(_ cliSessionID: String, forMobileSession mobileSessionID: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO chat_sessions (mobile_session_id, cli_session_id) VALUES (?, ?)
                    ON CONFLICT(mobile_session_id) DO UPDATE SET cli_session_id = excluded.cli_session_id
                    """,
                arguments: [mobileSessionID, cliSessionID]
            )
        }
    }

    // MARK: - Relay processed set (duplicate-delivery idempotency)

    func isRelayProcessed(_ recordName: String) throws -> Bool {
        try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM relay_processed WHERE record_name = ?)",
                arguments: [recordName]
            ) ?? false
        }
    }

    func markRelayProcessed(_ recordName: String, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO relay_processed (record_name, processed_at) VALUES (?, ?)",
                arguments: [recordName, date.timeIntervalSince1970]
            )
        }
    }

    /// Retention: drops processed-set entries older than `date`. Safety rests
    /// on two guards: (1) the status-echo guard in processAction (a record whose
    /// status is already applied/failed is skipped without touching the processed
    /// set), and (2) the relay buffer retaining full history until hygiene deletes
    /// aged records — a duplicate re-delivery of a very old record is still caught
    /// by its echo status before any write occurs.
    func pruneRelayProcessed(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM relay_processed WHERE processed_at < ?",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }

    // MARK: - Account-change reset

    /// Clears all sync state derived from the CloudKit account so the next
    /// publish/relay cycle starts clean against the new account. Nothing
    /// account-specific survives: slice hashes, relay change token, processed
    /// set, and chat-session mapping are all wiped. The hygiene stamp in
    /// hub_meta is intentionally retained — hygiene timing is account-agnostic.
    /// The generation counter is bumped so any in-flight publishOnce cycle can
    /// detect the reset and abort before recording stale hashes.
    func wipeSyncState() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM slice_state")
            try db.execute(
                sql: "DELETE FROM hub_meta WHERE key = ?",
                arguments: [RelayProcessor.relayTokenKey]
            )
            try db.execute(sql: "DELETE FROM relay_processed")
            try db.execute(sql: "DELETE FROM chat_sessions")
            // Bump the generation so any in-flight publishOnce cycle can detect the
            // wipe and abort before writing stale hashes for the new account.
            try db.execute(sql: """
                INSERT INTO hub_meta (key, value)
                VALUES ('sync_generation',
                        CAST(COALESCE((SELECT value FROM hub_meta WHERE key = 'sync_generation'), '0') AS INTEGER) + 1)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """)
        }
    }

    /// Returns the current sync generation counter. Starts at 0; bumped by
    /// `wipeSyncState()` so `SlicePublisher` can detect a mid-cycle account reset
    /// and abort before recording stale hashes.
    func generation() throws -> Int {
        let raw = try metaValue(forKey: "sync_generation")
        return raw.flatMap(Int.init) ?? 0
    }
}
