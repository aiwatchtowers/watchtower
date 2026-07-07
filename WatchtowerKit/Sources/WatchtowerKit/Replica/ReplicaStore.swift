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
    private let writer: any DatabaseWriter
    /// Distinct record_names whose payloads failed to decode, so the count is
    /// a true tally of bad rows (not fetch passes) and each is logged once.
    private let corrupt = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Same log-once idea for pending_actions rows, kept separate so
    /// `corruptCount()` stays a pure slice-record tally.
    private let corruptPending = OSAllocatedUnfairLock(initialState: Set<String>())
    private let logger = Logger(subsystem: "WatchtowerKit", category: "ReplicaStore")

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
                    updated_at REAL NOT NULL
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
        decodePendingActions(try Row.fetchAll(
            db,
            sql: "SELECT * FROM pending_actions ORDER BY created_at, action_id"
        ))
    }

    /// Overlay rows targeting one slice record (`target-42`), oldest first.
    public func pendingActions(forEntity recordName: String) throws -> [PendingAction] {
        try writer.read { db in
            decodePendingActions(try Row.fetchAll(
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
    private func decodePendingActions(_ rows: [Row]) -> [PendingAction] {
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

    // MARK: - Chat (sessions + assembled messages)

    /// All chat threads, most recently active first (stable tie-break on id).
    public func chatSessions() throws -> [ChatSession] {
        try writer.read { db in try chatSessions(from: db) }
    }

    /// `chatSessions()` against an ALREADY-OPEN database — for the app's
    /// ValueObservation tracking closures, where a nested `writer.read`
    /// would trap on DatabasePool reentrancy (same rule as
    /// `fetchAll(_:kind:from:)`).
    public func chatSessions(from db: Database) throws -> [ChatSession] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM chat_sessions ORDER BY updated_at DESC, session_id"
        )
        return rows.map(ChatSession.init(row:))
    }

    /// One thread's turns, oldest first. Both rows of a send share their
    /// created_at, so the user turn sorts before the assistant reply it
    /// prompted via the role tie-break.
    public func chatMessages(inSession sessionID: String) throws -> [ChatMessage] {
        try writer.read { db in try chatMessages(inSession: sessionID, from: db) }
    }

    /// `chatMessages(inSession:)` against an ALREADY-OPEN database — for
    /// ValueObservation tracking closures (see `chatSessions(from:)`).
    public func chatMessages(inSession sessionID: String, from db: Database) throws -> [ChatMessage] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_messages WHERE session_id = ?
                ORDER BY created_at, CASE role WHEN 'user' THEN 0 ELSE 1 END, message_id
                """,
            arguments: [sessionID]
        )
        return rows.map(ChatMessage.init(row:))
    }

    /// ChatAssembler.send's local persistence (internal: the app sends
    /// through the assembler). One transaction: session upsert (the FIRST
    /// turn sets the title, later turns only bump updated_at), the user turn
    /// (born complete), and the empty assistant placeholder that chunks
    /// keyed by `assistantMessageID` will fill.
    func insertChatTurn(
        sessionID: String,
        title: String,
        userMessageID: String,
        assistantMessageID: String,
        text: String,
        createdAt: Date
    ) throws {
        try writer.write { db in
            let timestamp = createdAt.timeIntervalSince1970
            try db.execute(
                sql: """
                    INSERT INTO chat_sessions (session_id, title, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET updated_at = excluded.updated_at
                    """,
                arguments: [sessionID, title, timestamp, timestamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO chat_messages (message_id, session_id, role, text, is_complete, created_at)
                    VALUES (?, ?, 'user', ?, 1, ?), (?, ?, 'assistant', '', 0, ?)
                    """,
                arguments: [
                    userMessageID, sessionID, text, timestamp,
                    assistantMessageID, sessionID, timestamp
                ]
            )
        }
    }

    /// Outcome of `applyChatChunk` — drives ChatAssembler's gap buffer.
    enum ChatChunkOutcome {
        /// Text appended (the next-in-order seq); more chunks expected.
        case applied
        /// This chunk completed the message (`is_complete` flipped).
        case completed
        /// Duplicate/lower-seq chunk, or the message is already complete.
        case ignored
        /// `seq` skips past `last_seq + 1` — nothing written.
        case gap
        /// No local row for `messageID` — nothing written.
        case unknownMessage
    }

    /// Applies one chunk to its assistant row in a single transaction,
    /// enforcing the frozen assembly contract (Plan 3 notes): per message
    /// ordered by seq, append only the next unseen seq, cut at the FIRST
    /// `done` — everything for that message is ignored afterward, including
    /// stale higher-seq leftovers of a redelivered shorter answer. A done
    /// chunk whose seq was already applied (its text arrived under the old
    /// record version) completes the message WITHOUT appending. `is_error`
    /// is meaningful only on the done chunk. Every branch is idempotent:
    /// RelayFeed replays whole batches after a mid-batch throw.
    func applyChatChunk(
        messageID: String,
        seq: Int,
        text: String,
        done: Bool,
        isError: Bool,
        receivedAt: Date
    ) throws -> ChatChunkOutcome {
        try writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT session_id, is_complete, last_seq FROM chat_messages WHERE message_id = ?",
                arguments: [messageID]
            ) else { return .unknownMessage }
            if row["is_complete"] as Bool { return .ignored }
            let lastSeq: Int = row["last_seq"]
            if seq <= lastSeq, !done { return .ignored }
            if seq > lastSeq + 1 { return .gap }
            try db.execute(
                sql: """
                    UPDATE chat_messages
                    SET text = text || ?, last_seq = max(last_seq, ?), is_complete = ?, is_error = ?
                    WHERE message_id = ?
                    """,
                arguments: [seq == lastSeq + 1 ? text : "", seq, done, done && isError, messageID]
            )
            try db.execute(
                sql: "UPDATE chat_sessions SET updated_at = ? WHERE session_id = ?",
                arguments: [receivedAt.timeIntervalSince1970, row["session_id"] as String]
            )
            return done ? .completed : .applied
        }
    }

    /// True while the assistant row exists, is incomplete, and no chunk has
    /// been applied yet — `ChatAssembler.firstChunkPending`'s read. A
    /// missing row reads false: an unknown message is not "waiting".
    func chatMessageAwaitingFirstChunk(_ messageID: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT is_complete = 0 AND last_seq < 0 FROM chat_messages WHERE message_id = ?",
                arguments: [messageID]
            ) ?? false
        }
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

/// One chat thread header (the local chat replica, written by ChatAssembler).
public struct ChatSession: Equatable, Identifiable {
    /// The wire sessionID.
    public let id: String
    /// First words of the opening message; never rewritten afterward.
    public let title: String
    public let createdAt: Date
    /// Bumped by every turn and applied chunk — the sessions list sorts on it.
    public let updatedAt: Date

    init(row: Row) {
        id = row["session_id"]
        title = row["title"]
        createdAt = Date(timeIntervalSince1970: row["created_at"])
        updatedAt = Date(timeIntervalSince1970: row["updated_at"])
    }
}

/// One turn of a chat thread. Assistant rows stream in via ChatAssembler —
/// text grows chunk by chunk until `isComplete`.
public struct ChatMessage: Equatable, Identifiable {
    public enum Role: String {
        case user
        case assistant
    }

    /// Assistant rows: the wire messageID chunks are keyed by. User rows use
    /// a disjoint "user-"-prefixed id (see ChatAssembler.send).
    public let id: String
    public let sessionID: String
    public let role: Role
    /// True only after an error-path final chunk (stream failure, watchdog
    /// timeout on the desktop).
    public let isError: Bool
    /// User turns are born complete; assistant rows flip at the first done
    /// chunk (the assembly cut).
    public let isComplete: Bool
    public let text: String
    public let createdAt: Date
    /// Highest applied chunk seq; -1 before the first chunk. Assembly
    /// plumbing, deliberately not public.
    let lastSeq: Int

    init(row: Row) {
        id = row["message_id"]
        sessionID = row["session_id"]
        // role is CHECK-constrained to the two rawValues; the fallback is
        // unreachable.
        role = Role(rawValue: row["role"]) ?? .assistant
        isError = row["is_error"]
        isComplete = row["is_complete"]
        text = row["text"]
        createdAt = Date(timeIntervalSince1970: row["created_at"])
        lastSeq = row["last_seq"]
    }
}
