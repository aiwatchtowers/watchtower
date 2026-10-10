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
/// Mechanism: `init(path:)` opens a `DatabasePool` (WAL) so ValueObservation
/// can read concurrently with the hydrator's writes on-device; `inMemory()`
/// uses a `DatabaseQueue` because GRDB pools require a file. Both are
/// `DatabaseWriter`s and ValueObservation tracks both, so tests exercise the
/// same code paths.
public final class ReplicaStore: Sendable {
    /// Widened from `private` to `internal`: read/written directly by the
    /// pending-actions and phone-recordings methods, which the split moved
    /// into `ReplicaStore+PendingActions.swift` / `ReplicaStore+PhoneRecordings.swift`.
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
    /// How many undecodable-heartbeat warnings were emitted. The phone reads
    /// the heartbeat on every liveness check, so the warning fires once per
    /// store, never per tick.
    private let undecodableHeartbeatLogs = OSAllocatedUnfairLock(initialState: 0)

    private static let dataTokenKey = "data_change_token"
    /// RelayFeed's cursor (Plan 4 decision 3: the phone's SINGLE relay
    /// consumer). Lives beside the data token in `replica_meta`.
    private static let relayTokenKey = "relay_change_token"
    /// NotificationCoordinator's alert-dedup high-water mark, Unix seconds
    /// (Plan 6 Task 4) — the newest `modifiedAt` the app has already alerted
    /// (or deliberately suppressed) about.
    private static let alertWatermarkKey = "notify_alert_watermark"

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
                    error_message TEXT,
                    reason TEXT,
                    result BLOB,
                    echo_status TEXT
                );
                \(Self.phoneRecordingsTableSQL(name: "phone_recordings", ifNotExists: true));
                CREATE TABLE IF NOT EXISTS phone_recording_marks (
                    recording_id TEXT NOT NULL
                        REFERENCES phone_recordings(recording_id) ON DELETE CASCADE,
                    offset_sec INTEGER NOT NULL CHECK(offset_sec >= 0),
                    PRIMARY KEY (recording_id, offset_sec)
                );
                \(Self.sliceAssetsTableSQL);
                """)
            // A replica created before `event_id` existed keeps its ledger:
            // the column is added in place (CREATE IF NOT EXISTS skipped it).
            let columns = try db.columns(in: "phone_recordings").map(\.name)
            if !columns.contains("event_id") {
                try db.execute(sql: "ALTER TABLE phone_recordings ADD COLUMN event_id TEXT")
            }
            if !columns.contains("failure_kind") {
                try db.execute(sql: "ALTER TABLE phone_recordings ADD COLUMN failure_kind TEXT")
            }
            // The same for an overlay written before it kept an echo's
            // reason, result and last in-flight status.
            let pendingColumns = try db.columns(in: "pending_actions").map(\.name)
            if !pendingColumns.contains("reason") {
                try db.execute(sql: "ALTER TABLE pending_actions ADD COLUMN reason TEXT")
            }
            if !pendingColumns.contains("result") {
                try db.execute(sql: "ALTER TABLE pending_actions ADD COLUMN result BLOB")
            }
            if !pendingColumns.contains("echo_status") {
                try db.execute(sql: "ALTER TABLE pending_actions ADD COLUMN echo_status TEXT")
            }
        }
        try upgradePhoneRecordingsStates()
    }

    /// The `phone_recordings` ledger. `recording` is a capture still being
    /// written: its row exists from the first second, so a capture cut short
    /// by a kill is finalized at the next launch.
    private static func phoneRecordingsTableSQL(name: String, ifNotExists: Bool) -> String {
        """
        CREATE TABLE \(ifNotExists ? "IF NOT EXISTS " : "")\(name) (
            recording_id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            duration_sec INTEGER NOT NULL,
            title_hint TEXT,
            sample_format TEXT NOT NULL,
            state TEXT NOT NULL
                CHECK(state IN ('recording','waiting','uploading','delivered','failed')),
            error_message TEXT,
            event_id TEXT,
            failure_kind TEXT
        )
        """
    }

    /// A ledger written before the `recording` state existed has a CHECK
    /// without it, and SQLite cannot alter a CHECK: the table is rebuilt
    /// with its rows. Foreign keys are off for the swap, so dropping the old
    /// table does not cascade into `phone_recording_marks`.
    private func upgradePhoneRecordingsStates() throws {
        let current = try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'phone_recordings'"
            )
        }
        guard let current, !current.contains("'recording'") else { return }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
            try db.inTransaction {
                let columns = """
                    recording_id, file_path, started_at, ended_at, duration_sec,
                    title_hint, sample_format, state, error_message, event_id, failure_kind
                    """
                try db.execute(sql: Self.phoneRecordingsTableSQL(name: "phone_recordings_upgrade", ifNotExists: false))
                try db.execute(sql: "INSERT INTO phone_recordings_upgrade (\(columns)) SELECT \(columns) FROM phone_recordings")
                try db.execute(sql: "DROP TABLE phone_recordings")
                try db.execute(sql: "ALTER TABLE phone_recordings_upgrade RENAME TO phone_recordings")
                return .commit
            }
        }
    }

    // MARK: - Ingest

    /// Applies one data-zone change batch in a single transaction: upserts
    /// changed records, removes deleted ones, persists the new token.
    ///
    /// The replica ingests DataZone ONLY — relay records (actions, uploads)
    /// are ignored here; RelayFeed reads the relay zone separately.
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
        let assets = Self.readAssets(of: batch.changed)
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
                try storeAsset(assets[record.recordName].flatMap { $0 }, recordName: record.recordName, in: db)
            }
            for name in batch.deletedRecordNames {
                try db.execute(sql: "DELETE FROM slice_records WHERE record_name = ?", arguments: [name])
                try db.execute(sql: "DELETE FROM slice_assets WHERE record_name = ?", arguments: [name])
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

    /// Forgets both change tokens (data and relay), so the next hydration
    /// and relay cycle re-read their zones from scratch; the stored rows
    /// stay and are upserted again. For a transport whose cursor restarts
    /// with the process (the phone's in-memory demo): without the reset its
    /// fresh tokens never pass the monotonic guard of a persisted replica.
    /// The alert watermark is kept.
    ///
    /// SPI (`@_spi(DemoTransport) import WatchtowerSync`), not plain public:
    /// against a persistent transport (CloudKit) the reset would replay the
    /// whole buffered zone on every call, so a caller must opt in by name —
    /// the phone's DEBUG demo bootstrap is the only one (final-review A-T11 N1).
    @_spi(DemoTransport)
    public func resetSyncTokens() throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM replica_meta WHERE key IN (?, ?)",
                arguments: [Self.dataTokenKey, Self.relayTokenKey]
            )
        }
    }

    // MARK: - Relay token (RelayFeed state) + heartbeat

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

    /// Age of the desktop heartbeat relative to `now`, read from the
    /// DataZone `heartbeat` record (mobile POC spec §4.1) that hydration
    /// stores in `slice_records`; nil = never seen. Negative when the desktop
    /// clock runs ahead of the phone's.
    ///
    /// Only `updated_at` is decoded, so no other field a newer Mac adds or
    /// reshapes can turn the Mac offline. A payload without a readable
    /// `updated_at` reads as never seen (conservative) and is logged once.
    public func heartbeatAge(now: Date = Date()) throws -> Duration? {
        let payload = try writer.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT payload FROM slice_records WHERE record_name = ?",
                arguments: [HeartbeatPayload.recordName]
            )
        }
        guard let payload else { return nil }
        guard let stamp = try? RelayCoder.makeDecoder().decode(HeartbeatStamp.self, from: payload) else {
            let firstTime = undecodableHeartbeatLogs.withLock { emitted -> Bool in
                guard emitted == 0 else { return false }
                emitted = 1
                return true
            }
            if firstTime {
                logger.warning("undecodable heartbeat payload, the Mac reads as offline")
            }
            return nil
        }
        return .seconds(now.timeIntervalSince(stamp.updatedAt))
    }

    /// The stored payload of one data-zone record (`heartbeat`,
    /// `device_grant-<id>`), from an ALREADY-OPEN database so it runs inside
    /// a ValueObservation tracking closure; nil when the record is absent.
    public func payload(forRecordName recordName: String, from db: Database) throws -> Data? {
        try Data.fetchOne(
            db,
            sql: "SELECT payload FROM slice_records WHERE record_name = ?",
            arguments: [recordName]
        )
    }

    /// Every stored payload of one data-zone kind (the WatchtowerKit slice
    /// mirrors decode them), from an ALREADY-OPEN database so it runs inside
    /// a ValueObservation tracking closure. Ordered by record name.
    public func payloads(of kind: SliceKind, from db: Database) throws -> [Data] {
        try Data.fetchAll(
            db,
            sql: "SELECT payload FROM slice_records WHERE kind = ? ORDER BY record_name",
            arguments: [kind.rawValue]
        )
    }

    /// Undecodable-heartbeat warnings emitted so far (for tests).
    func undecodableHeartbeatLogCount() -> Int {
        undecodableHeartbeatLogs.withLock { $0 }
    }

    /// The one heartbeat field liveness needs.
    private struct HeartbeatStamp: Decodable {
        let updatedAt: Date
    }

    // MARK: - Alert watermark (NotificationCoordinator dedup state)

    /// High-water `modifiedAt` of slice records the app has already raised
    /// (or deliberately suppressed) local notifications for. nil = never
    /// alerted — the state the coordinator's initial-hydrate storm
    /// suppression keys on, so an unreadable stored value also reads as nil:
    /// the failure mode is one silent re-arm of that suppression, never a
    /// notification storm.
    public func lastAlertedWatermark() throws -> Date? {
        guard let raw = try metaValue(Self.alertWatermarkKey), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Persists the alert watermark. Not monotonic-guarded: the coordinator
    /// is the single writer and only ever moves it forward.
    public func setLastAlertedWatermark(_ date: Date) throws {
        try writer.write { db in
            try Self.upsertMeta(db, key: Self.alertWatermarkKey, value: String(date.timeIntervalSince1970))
        }
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
