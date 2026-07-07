import Foundation
import GRDB
import os

/// Sort order for `ReplicaStore.fetchAll`. Replaces a raw ORDER BY SQL
/// fragment param: callers pick one of a fixed set of orderings instead of
/// interpolating SQL into the replica API.
public enum ReplicaSort: Sendable {
    case newestFirst
    case oldestFirst
    case recordName

    /// The ORDER BY fragment over `slice_records` columns
    /// (`record_name`, `modified_at`) this case maps to.
    fileprivate var orderByFragment: String {
        switch self {
        case .newestFirst: return "modified_at DESC, record_name"
        case .oldestFirst: return "modified_at ASC, record_name"
        case .recordName: return "record_name"
        }
    }
}

/// The mobile-side mirror of DataZone: one generic table of slice payloads
/// (`slice_records`) plus the persisted data-zone change token. The UI reads
/// it via `fetchAll` (typed decode) or ValueObservation on `reader`.
///
/// The store also hosts the sidecar `pending_actions` table — the optimistic
/// overlay for relay actions the phone has enqueued but the desktop has not
/// yet echoed. It shares the pool so one ValueObservation pipeline drives
/// both the slice lists and their overlays. `slice_records` itself stays
/// hydration-only: pending actions never mutate replica rows (Plan 4
/// decision 4 — overlay, not mutation).
///
/// The local chat replica (`chat_sessions`/`chat_messages`) also lives here:
/// written only by ChatAssembler (sends + chunk assembly), read by the chat
/// UI through the same pool so one ValueObservation pipeline drives it too.
///
/// Mechanism: `init(path:)` opens a `DatabasePool` (WAL) so ValueObservation
/// can read concurrently with the hydrator's writes on-device; `inMemory()`
/// uses a `DatabaseQueue` because GRDB pools require a file. Both are
/// `DatabaseWriter`s and ValueObservation tracks both, so tests exercise the
/// same code paths.
public final class ReplicaStore: Sendable {
    /// Widened from `private` to `internal`: read/written directly by the
    /// chat and pending-actions methods, which the split moved into
    /// `ReplicaStore+Chat.swift` / `ReplicaStore+PendingActions.swift`.
    let writer: any DatabaseWriter
    /// Distinct record_names whose payloads failed to decode, so the count is
    /// a true tally of bad rows (not fetch passes) and each is logged once.
    private let corrupt = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Same log-once idea for pending_actions rows, kept separate so
    /// `corruptCount()` stays a pure slice-record tally.
    ///
    /// Widened from `private` to `internal`: read by `decodePendingActions`
    /// in `ReplicaStore+PendingActions.swift` after the split.
    let corruptPending = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Widened from `private` to `internal`: read by `decodePendingActions`
    /// in `ReplicaStore+PendingActions.swift` after the split.
    let logger = Logger(subsystem: "WatchtowerKit", category: "ReplicaStore")

    private static let dataTokenKey = "data_change_token"
    /// RelayFeed's cursor (Plan 4 decision 3: the phone's SINGLE relay
    /// consumer). Lives beside the data token in `replica_meta`.
    private static let relayTokenKey = "relay_change_token"
    /// Last desktop heartbeat `updatedAt`, Unix seconds (via RelayFeed).
    private static let heartbeatKey = "desktop_heartbeat_at"

    public init(path: String) throws {
        writer = try DatabasePool(path: path)
        try createSchema()
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try createSchema()
    }

    public static func inMemory() throws -> ReplicaStore {
        try ReplicaStore(writer: DatabaseQueue())
    }

    /// Entry point for the UI's ValueObservation.
    public var reader: any DatabaseReader { writer }

    private func createSchema() throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS slice_records (
                    record_name TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    modified_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_slice_records_kind ON slice_records(kind);
                CREATE TABLE IF NOT EXISTS replica_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );
                CREATE TABLE IF NOT EXISTS pending_actions (
                    action_id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    entity_record_name TEXT,
                    payload BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('pending','failed')),
                    error_message TEXT
                );
                CREATE TABLE IF NOT EXISTS chat_sessions (
                    session_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    direct_mode INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS chat_messages (
                    message_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL CHECK(role IN ('user','assistant')),
                    text TEXT NOT NULL,
                    is_error INTEGER NOT NULL DEFAULT 0,
                    is_complete INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    last_seq INTEGER NOT NULL DEFAULT -1
                );
                CREATE INDEX IF NOT EXISTS idx_chat_messages_session ON chat_messages(session_id);
                """)
            // Migration for replicas created before Plan 5 Task 7:
            // CREATE TABLE IF NOT EXISTS leaves an existing chat_sessions
            // untouched, so the direct-mode column is added in place.
            // Existing rows read the DEFAULT 0 — every pre-existing session
            // stays on the relay until its owner explicitly opts in
            // (Decision 7: never a silent switch).
            if try !db.columns(in: "chat_sessions").contains(where: { $0.name == "direct_mode" }) {
                try db.execute(sql: "ALTER TABLE chat_sessions ADD COLUMN direct_mode INTEGER NOT NULL DEFAULT 0")
            }
        }
    }

    // MARK: - Ingest

    /// Applies one data-zone change batch in a single transaction: upserts
    /// changed records, removes deleted ones, persists the new token.
    ///
    /// The replica ingests DataZone ONLY — relay records (chat, actions) are
    /// ignored here; Plan 4's chat assembly reads the transport separately.
    /// Payloads are stored as opaque blobs without decoding, so a corrupt
    /// payload can never fail the batch or stall the token — corruption
    /// surfaces (and is skipped) in `fetchAll`.
    ///
    /// Returns `true` if the batch was applied, `false` if it was dropped by
    /// the monotonic guard (a stale/overlapping read). Callers should skip
    /// compaction when `false` — the batch's events are already behind the
    /// stored token.
    @discardableResult
    public func apply(_ batch: CloudChangeBatch) throws -> Bool {
        // JSONEncoder always emits valid UTF-8, so the nil branch is
        // unreachable; skipping only the token persistence would just
        // re-read the zone next cycle (safe — upserts are idempotent).
        let tokenJSON = String(bytes: try JSONEncoder().encode(batch.newToken), encoding: .utf8)
        return try writer.write { db in
            // Monotonic guard: a batch whose token is not newer than what we
            // already applied is a stale or overlapping read — e.g. a
            // reentrant hydration cycle that resumed after a newer one
            // committed. Its records are older versions of rows we already
            // hold, and compaction may have dropped the events it is based
            // on, so applying it would silently regress payloads. Drop it.
            let storedRaw = try String.fetchOne(
                db,
                sql: "SELECT value FROM replica_meta WHERE key = ?",
                arguments: [Self.dataTokenKey]
            )
            if let stored = Self.decodeToken(storedRaw), batch.newToken.value <= stored.value {
                return false
            }
            for record in batch.changed where record.zone == .data {
                try db.execute(
                    sql: """
                        INSERT INTO slice_records (record_name, kind, payload, modified_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(record_name) DO UPDATE SET
                            kind = excluded.kind,
                            payload = excluded.payload,
                            modified_at = excluded.modified_at
                        """,
                    arguments: [
                        record.recordName, record.kind,
                        record.payload, record.modifiedAt.timeIntervalSince1970
                    ]
                )
            }
            for name in batch.deletedRecordNames {
                try db.execute(sql: "DELETE FROM slice_records WHERE record_name = ?", arguments: [name])
            }
            if let tokenJSON {
                try Self.upsertMeta(db, key: Self.dataTokenKey, value: tokenJSON)
            }
            return true
        }
    }

    private static func decodeToken(_ raw: String?) -> CloudChangeToken? {
        guard let raw else { return nil }
        return try? JSONDecoder().decode(CloudChangeToken.self, from: Data(raw.utf8))
    }

    private static func upsertMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO replica_meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value]
        )
    }

    private func metaValue(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = ?", arguments: [key])
        }
    }

    public func storedToken() throws -> CloudChangeToken? {
        try token(forKey: Self.dataTokenKey, zoneLabel: "data")
    }

    private func token(forKey key: String, zoneLabel: String) throws -> CloudChangeToken? {
        guard let raw = try metaValue(key) else { return nil }
        guard let token = Self.decodeToken(raw) else {
            // Corrupted token → full re-read from the zone; both consumers
            // replay safely (apply is an idempotent upsert, mirroring
            // RelayProcessor; RelayFeed's routing is idempotent too).
            logger.warning("unreadable \(zoneLabel, privacy: .public)-zone change token, re-reading the zone from scratch")
            return nil
        }
        return token
    }

    // MARK: - Relay token + heartbeat (RelayFeed state)

    /// RelayFeed's persisted relay-zone cursor. Internal BY DESIGN (Plan 4
    /// decision 3): the app consumes relay records through RelayFeed only,
    /// so nothing outside the Kit can grow a second relay consumer.
    func relayToken() throws -> CloudChangeToken? {
        try token(forKey: Self.relayTokenKey, zoneLabel: "relay")
    }

    /// Persists RelayFeed's relay-zone cursor with the same monotonic guard
    /// as `apply`'s data token: a token not newer than the stored one is a
    /// stale/overlapping read — returns `false` without writing. RelayFeed
    /// drops such batches before routing; this guard is the belt to that
    /// suspenders (mirrors the replica's coalescing + guard pairing).
    @discardableResult
    func setRelayToken(_ token: CloudChangeToken) throws -> Bool {
        // JSONEncoder always emits valid UTF-8; see the note in `apply`.
        let tokenJSON = String(bytes: try JSONEncoder().encode(token), encoding: .utf8)
        return try writer.write { db in
            let storedRaw = try String.fetchOne(
                db,
                sql: "SELECT value FROM replica_meta WHERE key = ?",
                arguments: [Self.relayTokenKey]
            )
            if let stored = Self.decodeToken(storedRaw), token.value <= stored.value {
                return false
            }
            if let tokenJSON {
                try Self.upsertMeta(db, key: Self.relayTokenKey, value: tokenJSON)
            }
            return true
        }
    }

    /// Records the desktop's heartbeat (routed here by RelayFeed). The write
    /// is non-monotonic — an older `updatedAt` overwrites a newer one — which
    /// is unreachable today: the transport's batches carry only the latest
    /// state per recordName and RelayFeed drops stale batches before routing.
    func setHeartbeat(updatedAt: Date) throws {
        try writer.write { db in
            try Self.upsertMeta(db, key: Self.heartbeatKey, value: String(updatedAt.timeIntervalSince1970))
        }
    }

    /// Age of the last desktop heartbeat relative to `now`; nil = never seen
    /// (an unreadable stored value also reads as never — conservative).
    /// Negative when the desktop clock runs ahead of the phone's.
    public func heartbeatAge(now: Date = Date()) throws -> Duration? {
        guard let raw = try metaValue(Self.heartbeatKey), let seconds = TimeInterval(raw) else { return nil }
        return .seconds(now.timeIntervalSince(Date(timeIntervalSince1970: seconds)))
    }

    // MARK: - Typed reads

    /// Decodes every stored payload of `kind` into a model via
    /// RowPayloadCoder → `init(row:)`. Undecodable payloads are skipped and
    /// counted (`corruptCount()`) — one bad record must never crash a list.
    ///
    /// Typed sorting on model fields happens in memory after decode; `sort`
    /// only orders the underlying `slice_records` scan. Default: most recent
    /// first.
    public func fetchAll<T: FetchableRecord>(
        _ type: T.Type,
        kind: SliceKind,
        sort: ReplicaSort = .newestFirst
    ) throws -> [T] {
        try writer.read { db in try fetchAll(type, kind: kind, from: db, sort: sort) }
    }

    /// Decodes stored payloads of `kind` from an ALREADY-OPEN database — for use
    /// inside a ValueObservation tracking closure, where opening a nested
    /// `writer.read` would trap on DatabasePool reentrancy. The observation must
    /// call THIS overload with its own `db` so region tracking is recorded on the
    /// tracked connection.
    ///
    /// Typed sorting on model fields happens in memory after decode; `sort`
    /// only orders the underlying `slice_records` scan. Default: most recent
    /// first.
    public func fetchAll<T: FetchableRecord>(
        _ type: T.Type,
        kind: SliceKind,
        from db: Database,
        sort: ReplicaSort = .newestFirst
    ) throws -> [T] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT record_name, payload FROM slice_records WHERE kind = ? ORDER BY \(sort.orderByFragment)",
            arguments: [kind.rawValue]
        )
        var decoded: [T] = []
        var badNames: [String] = []
        for row in rows {
            let payload: Data = row["payload"]
            do {
                decoded.append(try T(row: RowPayloadCoder.row(from: payload)))
            } catch {
                badNames.append(row["record_name"])
            }
        }
        if !badNames.isEmpty {
            // Track distinct corrupt record_names, and log only on the first
            // sighting of each — an observation-driven list refetches on every
            // change, so a persistently-bad row must not re-log forever.
            let names = badNames // immutable copy for the @Sendable withLock closure
            let firstSeen = corrupt.withLock { seen -> [String] in
                names.filter { seen.insert($0).inserted }
            }
            for name in firstSeen {
                logger.warning("undecodable \(kind.rawValue, privacy: .public) payload skipped: \(name, privacy: .public)")
            }
        }
        return decoded
    }

    /// Number of DISTINCT record_names whose payloads failed to decode across
    /// all `fetchAll` passes since init.
    public func corruptCount() -> Int {
        corrupt.withLock { $0.count }
    }
}
