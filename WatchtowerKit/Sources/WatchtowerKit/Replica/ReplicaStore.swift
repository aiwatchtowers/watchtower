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
    private let writer: any DatabaseWriter
    /// Distinct record_names whose payloads failed to decode, so the count is
    /// a true tally of bad rows (not fetch passes) and each is logged once.
    private let corrupt = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Same log-once idea for pending_actions rows, kept separate so
    /// `corruptCount()` stays a pure slice-record tally.
    private let corruptPending = OSAllocatedUnfairLock(initialState: Set<String>())
    private let logger = Logger(subsystem: "WatchtowerKit", category: "ReplicaStore")

    private static let dataTokenKey = "data_change_token"

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
                """)
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
                try db.execute(
                    sql: """
                        INSERT INTO replica_meta (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [Self.dataTokenKey, tokenJSON]
                )
            }
            return true
        }
    }

    private static func decodeToken(_ raw: String?) -> CloudChangeToken? {
        guard let raw else { return nil }
        return try? JSONDecoder().decode(CloudChangeToken.self, from: Data(raw.utf8))
    }

    public func storedToken() throws -> CloudChangeToken? {
        let raw = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = ?", arguments: [Self.dataTokenKey])
        }
        guard let raw else { return nil }
        guard let token = Self.decodeToken(raw) else {
            // Corrupted token → full re-read from the zone; apply is an
            // idempotent upsert, so the replay is safe (mirrors RelayProcessor).
            logger.warning("unreadable data-zone change token, re-reading the zone from scratch")
            return nil
        }
        return token
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

    // MARK: - Pending actions (optimistic overlay)

    /// All overlay rows, oldest first (stable: created_at, then action_id).
    /// Failed rows stay visible until the user retries or dismisses them.
    public func pendingActions() throws -> [PendingAction] {
        try writer.read { db in try pendingActions(from: db) }
    }

    /// `pendingActions()` against an ALREADY-OPEN database — for the app's
    /// ValueObservation tracking closures, where a nested `writer.read` would
    /// trap on DatabasePool reentrancy (same rule as `fetchAll(_:kind:from:)`).
    public func pendingActions(from db: Database) throws -> [PendingAction] {
        try decodePendingActions(Row.fetchAll(
            db,
            sql: "SELECT * FROM pending_actions ORDER BY created_at, action_id"
        ))
    }

    /// Overlay rows targeting one slice record (`target-42`), oldest first.
    public func pendingActions(forEntity recordName: String) throws -> [PendingAction] {
        try writer.read { db in
            try decodePendingActions(Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM pending_actions WHERE entity_record_name = ?
                    ORDER BY created_at, action_id
                    """,
                arguments: [recordName]
            ))
        }
    }

    /// Deletes one overlay row. Public for the app's "Dismiss" affordance on
    /// failed actions; unknown ids are a no-op (DELETE matches nothing).
    public func removePendingAction(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM pending_actions WHERE action_id = ?", arguments: [id])
        }
    }

    /// ActionOutbox's write path (internal: the app enqueues via the outbox,
    /// never by inserting rows directly). Stores the wire-encoded payload so
    /// the overlay can re-surface the full request (retry re-enqueues it).
    func insertPendingAction(_ action: ActionRequestPayload, entityRecordName: String?) throws {
        let payload = try RelayCoder.makeEncoder().encode(action)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_actions
                        (action_id, kind, entity_record_name, payload, created_at, state)
                    VALUES (?, ?, ?, ?, ?, 'pending')
                    """,
                arguments: [
                    action.id, action.kind.rawValue, entityRecordName,
                    payload, action.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    /// Flips one overlay row to `failed` (desktop echo). Unknown ids are a
    /// no-op: the echo may be a redelivery for a row the sweep already
    /// removed, or an action whose pending insert never happened.
    func markPendingActionFailed(id: String, errorMessage: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE pending_actions SET state = 'failed', error_message = ? WHERE action_id = ?",
                arguments: [errorMessage, id]
            )
        }
    }

    /// Fails every still-pending row created strictly before `cutoff` in one
    /// transaction; returns the affected ids (oldest first). Already-failed
    /// rows keep their (more informative) desktop error message.
    func sweepPendingActions(before cutoff: Date, errorMessage: String) throws -> [String] {
        try writer.write { db in
            let predicate = "state = 'pending' AND created_at < ?"
            let ids = try String.fetchAll(
                db,
                sql: "SELECT action_id FROM pending_actions WHERE \(predicate) ORDER BY created_at, action_id",
                arguments: [cutoff.timeIntervalSince1970]
            )
            guard !ids.isEmpty else { return [] }
            try db.execute(
                sql: "UPDATE pending_actions SET state = 'failed', error_message = ? WHERE \(predicate)",
                arguments: [errorMessage, cutoff.timeIntervalSince1970]
            )
            return ids
        }
    }

    /// Maps rows to PendingAction, skipping (and logging once, keyed by
    /// action_id) any whose payload no longer decodes. These blobs are written
    /// by this module from a just-encoded payload, so a failure here is a
    /// programmer error — but one bad row must never take down the overlay.
    private func decodePendingActions(_ rows: [Row]) throws -> [PendingAction] {
        let decoder = RelayCoder.makeDecoder()
        var decoded: [PendingAction] = []
        var badIDs: [String] = []
        for row in rows {
            let id: String = row["action_id"]
            guard let action = try? decoder.decode(ActionRequestPayload.self, from: row["payload"] as Data),
                  let state = PendingAction.State(rawValue: row["state"]) else {
                badIDs.append(id)
                continue
            }
            decoded.append(PendingAction(
                id: id,
                action: action,
                entityRecordName: row["entity_record_name"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                state: state,
                errorMessage: row["error_message"]
            ))
        }
        let firstSeen = corruptPending.withLock { seen -> [String] in
            badIDs.filter { seen.insert($0).inserted }
        }
        for id in firstSeen {
            logger.warning("undecodable pending_actions row skipped: \(id, privacy: .public)")
        }
        return decoded
    }
}

/// One optimistic-overlay row: an action the phone enqueued into the relay
/// that the desktop has not yet resolved. View models join these over the
/// slice models by `entityRecordName` (strike-through/pending chip, error
/// banner on `failed`).
///
/// `state` is the authoritative overlay state — the embedded `action` keeps
/// its as-enqueued `.pending` status even after a failed echo flips the row.
public struct PendingAction: Equatable, Identifiable {
    public enum State: String {
        case pending
        case failed
    }

    /// The `ActionRequestPayload.id` (also the row's primary key).
    public let id: String
    /// The request exactly as written to the relay zone.
    public let action: ActionRequestPayload
    /// Full recordName of the slice row this action targets (`target-42`);
    /// nil for entity-less kinds (`task_create`).
    public let entityRecordName: String?
    public let createdAt: Date
    public let state: State
    /// The desktop echo's message, or the silent-pending sweep text; nil
    /// while `state == .pending`.
    public let errorMessage: String?
}
