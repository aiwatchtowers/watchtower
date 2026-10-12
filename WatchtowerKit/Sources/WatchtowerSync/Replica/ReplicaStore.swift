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
    /// (`plain_name`, `modified_at`) this case maps to. `record_name` is the
    /// opaque wire name, so names order by the plain record name.
    fileprivate var orderByFragment: String {
        switch self {
        case .newestFirst: return "modified_at DESC, plain_name"
        case .oldestFirst: return "modified_at ASC, plain_name"
        case .recordName: return "plain_name"
        }
    }
}

/// The mobile-side mirror of DataZone: one generic table of slice records
/// (`slice_records`) plus the persisted data-zone change token. The UI reads
/// it via `fetchAll` (typed decode) or ValueObservation on `reader`.
///
/// Ciphertext at rest (mobile E2E spec §2.6, replica format 2): `payload`
/// holds the hub's envelope and `slice_assets.data` the sealed asset bytes.
/// `apply` verifies each envelope's hub signature with the public key (which
/// reads while the phone is locked) and keeps its `(epoch, seq)` as the
/// rollback guard; `indexPending` opens rows with the epoch keys and fills
/// their plain `kind` and record name (D11); every read opens again and
/// returns the frame's payload. `record_name` is the opaque wire name.
///
/// The store also hosts the sidecar `pending_actions` table — the optimistic
/// overlay for relay actions the phone has enqueued but the desktop has not
/// yet echoed. It shares the pool so one ValueObservation pipeline drives
/// both the slice lists and their overlays. `slice_records` itself stays
/// hydration-only: pending actions never mutate replica rows (Plan 4
/// decision 4 — overlay, not mutation).
///
/// Mechanism: `init(path:opener:)` opens a `DatabasePool` (WAL) so
/// ValueObservation can read concurrently with the hydrator's writes
/// on-device; `inMemory(opener:)` uses a `DatabaseQueue` because GRDB pools
/// require a file. Both are `DatabaseWriter`s and ValueObservation tracks
/// both, so tests exercise the same code paths.
public final class ReplicaStore: Sendable {
    /// Widened from `private` to `internal`: read/written directly by the
    /// pending-actions and phone-recordings methods, which the split moved
    /// into `ReplicaStore+PendingActions.swift` / `ReplicaStore+PhoneRecordings.swift`.
    let writer: any DatabaseWriter
    /// Verifies at apply, opens at read.
    let opener: any ReplicaOpening
    /// Distinct wire names whose rows failed to open or decode, so the count
    /// is a true tally of bad rows (not fetch passes) and each is logged once.
    private let corrupt = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Distinct wire names refused at apply: a bad signature, another hub, a
    /// malformed envelope, an older version of a stored record.
    private let rejected = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Distinct wire names of a newer envelope version or suite.
    private let newerFormat = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Key-store failures other than "locked" already logged, by cause.
    private let keyFailures = OSAllocatedUnfairLock(initialState: Set<String>())
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
    /// The replica's on-disk format. A store of any other format drops its
    /// slice rows, assets and both change tokens on open (hard cut, spec
    /// §2.8): format 1 held plaintext payloads.
    private static let formatKey = "replica_format"
    private static let format = "2"

    public init(path: String, opener: any ReplicaOpening) throws {
        writer = try DatabasePool(path: path)
        self.opener = opener
        try createSchema()
    }

    private init(writer: any DatabaseWriter, opener: any ReplicaOpening) throws {
        self.writer = writer
        self.opener = opener
        try createSchema()
    }

    public static func inMemory(opener: any ReplicaOpening) throws -> ReplicaStore {
        try ReplicaStore(writer: DatabaseQueue(), opener: opener)
    }

    /// Entry point for the UI's ValueObservation.
    public var reader: any DatabaseReader { writer }

    private func createSchema() throws {
        let wiped = try writer.write { db -> Bool in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS replica_meta (key TEXT PRIMARY KEY, value TEXT)")
            let stored = try String.fetchOne(
                db, sql: "SELECT value FROM replica_meta WHERE key = ?", arguments: [Self.formatKey])
            guard stored != Self.format else { return false }
            // `pending_actions` (whose pre-E2E rows the `wire_name` upgrade
            // below drops), `phone_recordings` (with marks), the alert
            // watermark and `envelope_seq_ceiling` (F29) stay.
            try db.execute(sql: "DROP TABLE IF EXISTS slice_records; DROP TABLE IF EXISTS slice_assets; DROP TABLE IF EXISTS data_seen")
            try db.execute(
                sql: "DELETE FROM replica_meta WHERE key IN (?, ?)", arguments: [Self.dataTokenKey, Self.relayTokenKey])
            try Self.upsertMeta(db, key: Self.formatKey, value: Self.format)
            return stored != nil
        }
        if wiped {
            logger.notice("replica format changed: slice records and change tokens dropped, the zone is re-read")
        }
        let droppedPlaintext = try writer.write { db -> Bool in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS slice_records (
                    record_name TEXT PRIMARY KEY,
                    plain_name TEXT,
                    kind TEXT,
                    epoch INTEGER NOT NULL,
                    seq INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    modified_at REAL NOT NULL,
                    needs_index INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX IF NOT EXISTS idx_slice_records_kind ON slice_records(kind);
                CREATE INDEX IF NOT EXISTS idx_slice_records_plain_name ON slice_records(plain_name);
                CREATE INDEX IF NOT EXISTS idx_slice_records_needs_index ON slice_records(needs_index);
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
                    echo_status TEXT,
                    wire_name TEXT
                );
                \(Self.phoneRecordingsTableSQL(name: "phone_recordings", ifNotExists: true));
                CREATE TABLE IF NOT EXISTS phone_recording_marks (
                    recording_id TEXT NOT NULL
                        REFERENCES phone_recordings(recording_id) ON DELETE CASCADE,
                    offset_sec INTEGER NOT NULL CHECK(offset_sec >= 0),
                    PRIMARY KEY (recording_id, offset_sec)
                );
                \(Self.sliceAssetsTableSQL);
                \(Self.relaySeenTableSQL);
                \(Self.dataSeenTableSQL);
                """)
            return try upgradeSidecarColumns(db)
        }
        if droppedPlaintext {
            // The deleted cells were zeroed (secure_delete); a TRUNCATE
            // checkpoint moves the zeroed pages into the database file and
            // empties the WAL, so no plaintext copy stays in either.
            try writer.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        try upgradePhoneRecordingsStates()
    }

    /// Columns added to the sidecar tables after they first shipped, added in
    /// place (CREATE IF NOT EXISTS skips an existing table). Returns whether
    /// pre-E2E plaintext overlay rows were deleted (the caller checkpoints).
    private func upgradeSidecarColumns(_ db: Database) throws -> Bool {
        // A replica created before `event_id` existed keeps its ledger:
        // the column is added in place (CREATE IF NOT EXISTS skipped it).
        let columns = try db.columns(in: "phone_recordings").map(\.name)
        if !columns.contains("event_id") {
            try db.execute(sql: "ALTER TABLE phone_recordings ADD COLUMN event_id TEXT")
        }
        if !columns.contains("failure_kind") {
            try db.execute(sql: "ALTER TABLE phone_recordings ADD COLUMN failure_kind TEXT")
        }
        // Mobile E2E: the sealed upload record (kept for every re-send), its wire name, and the sealed file.
        for (name, type) in [("envelope", "BLOB"), ("wire_name", "TEXT"), ("sealed_path", "TEXT")]
        where !columns.contains(name) {
            try db.execute(sql: "ALTER TABLE phone_recordings ADD COLUMN \(name) \(type)")
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
        // Mobile E2E: `payload` is the sealed envelope sent under `wire_name`. A row from before holds a
        // plaintext action for a hub the hard cut removed (no echo can ever come): dropped, so no plaintext
        // action stays at rest.
        guard !pendingColumns.contains("wire_name") else { return false }
        try db.execute(sql: "ALTER TABLE pending_actions ADD COLUMN wire_name TEXT")
        // secure_delete zero-fills the freed cells, so the plaintext does not
        // linger in free pages; this connection keeps it on from here (the
        // replica holds ciphertext, the cost is a little extra write).
        try db.execute(sql: "PRAGMA secure_delete = ON")
        try db.execute(sql: "DELETE FROM pending_actions")
        let dropped = db.changesCount
        guard dropped > 0 else { return false }
        logger.notice("dropped \(dropped) pre-E2E pending actions")
        return true
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
            failure_kind TEXT,
            envelope BLOB,
            wire_name TEXT,
            sealed_path TEXT
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
                    title_hint, sample_format, state, error_message, event_id, failure_kind,
                    envelope, wire_name, sealed_path
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

    /// Applies one data-zone change batch in a single transaction: stores
    /// verified envelopes, removes deleted ones (by wire name), persists the
    /// new token.
    ///
    /// The replica ingests DataZone ONLY — relay records (actions, uploads)
    /// are ignored here; RelayFeed reads the relay zone separately. Before
    /// the transaction each envelope's hub signature is checked with the
    /// public key (`opener.verify`), so this works while the phone is locked:
    /// - a signal record (F12) and another phone's keybox (F13) are skipped
    ///   silently;
    /// - a bad signature, another hub, a malformed envelope, or an older
    ///   `(epoch, seq)` than the stored row is skipped and counted
    ///   (`rejectedCount`), never stored; the same version is a no-op;
    /// - a newer envelope version or suite is stored unindexed and counted
    ///   (`newerFormatCount`): an updated app opens it without a refetch;
    /// - a key that cannot be read (`KeyStoreError.locked` before the first
    ///   unlock, no link yet) throws: nothing of the batch is stored and the
    ///   token is kept (F15), so nothing is skipped while the token moves.
    /// Rows a fixed name identifies (`heartbeat`, this phone's keybox) get
    /// their plain name and kind at once; the others stay unindexed until
    /// `indexPending` opens them. A record that cannot be decoded after
    /// opening never fails the batch — it surfaces (and is skipped) in reads.
    ///
    /// Returns `true` if the batch was applied, `false` if it was dropped by
    /// the monotonic guard (a stale/overlapping read). Callers should skip
    /// compaction when `false` — the batch's events are already behind the
    /// stored token.
    @discardableResult
    public func apply(_ batch: CloudChangeBatch) throws -> Bool {
        try applyCounting(batch) != nil
    }

    /// `apply`, returning how many records it stored (refused, rolled-back,
    /// unchanged, signal and other-phone keybox records are not counted), or
    /// nil when the monotonic guard dropped the batch. The hydrator's count.
    func applyCounting(_ batch: CloudChangeBatch) throws -> Int? {
        // JSONEncoder always emits valid UTF-8, so the nil branch is
        // unreachable; skipping only the token persistence would just
        // re-read the zone next cycle (safe — upserts are idempotent).
        let tokenJSON = String(bytes: try JSONEncoder().encode(batch.newToken), encoding: .utf8)
        let (accepted, refused) = try verify(batch.changed)
        let assets = Self.readAssets(of: accepted.map(\.record))
        let outcome = try writer.write { db -> (applied: Bool, stored: Int, rolledBack: [String]) in
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
                return (false, 0, [])
            }
            var rolledBack: [String] = []
            var stored = 0
            for item in accepted {
                let name = item.record.recordName
                if let version = item.version {
                    // The high-water mark, not the row: it survives a deletion and a newer-format row
                    // (stored as (0, 0)), so neither can open the door to replaying an older envelope.
                    if let seen = try Self.seenVersion(of: name, in: db) {
                        if version == seen { continue }
                        if version < seen {
                            rolledBack.append(name)
                            continue
                        }
                    }
                    try Self.recordSeen(name, version: version, in: db)
                }
                stored += 1
                try upsert(item, in: db)
                try storeAsset(assets[name].flatMap { $0 }, recordName: name, in: db)
            }
            for name in batch.deletedRecordNames {
                try db.execute(sql: "DELETE FROM slice_records WHERE record_name = ?", arguments: [name])
                try db.execute(sql: "DELETE FROM slice_assets WHERE record_name = ?", arguments: [name])
            }
            if let tokenJSON {
                try Self.upsertMeta(db, key: Self.dataTokenKey, value: tokenJSON)
            }
            return (true, stored, rolledBack)
        }
        guard outcome.applied else { return nil }
        for (name, reason) in refused { noteRejected(name, reason: reason) }
        for name in outcome.rolledBack { noteRejected(name, reason: "rolledBack") }
        for item in accepted where item.version == nil { noteNewerFormat(item.record.recordName) }
        return outcome.stored
    }

    /// The data records of a batch this replica stores, verified, and the
    /// ones it refuses. Signals and other phones' keyboxes are in neither.
    /// A key-store error (locked, no link yet) propagates: apply aborts.
    private func verify(
        _ records: [CloudRecord]
    ) throws -> (accepted: [VerifiedRecord], refused: [(wireName: String, reason: String)]) {
        var accepted: [VerifiedRecord] = []
        var refused: [(wireName: String, reason: String)] = []
        for record in records where record.zone == .data {
            if record.kind == WireKind.signal { continue }
            if record.recordName.hasPrefix(Self.keyboxPrefix), opener.fixedName(record.recordName) == nil { continue }
            do {
                let header = try opener.verify(wireName: record.recordName, envelope: record.payload)
                accepted.append(VerifiedRecord(record: record, version: RecordVersion(header)))
            } catch let error as EnvelopeError {
                if Self.isNewerFormat(error) {
                    accepted.append(VerifiedRecord(record: record, version: nil))
                } else {
                    refused.append((record.recordName, Self.code(error)))
                }
            }
        }
        return (accepted, refused)
    }

    /// The `(epoch, seq)` of a verified envelope; nil for a newer format,
    /// which cannot be parsed and so carries no version this build can read.
    private struct VerifiedRecord {
        let record: CloudRecord
        let version: RecordVersion?
    }

    /// Envelope versions compare as `(epoch, seq)`, epoch first.
    private struct RecordVersion: Comparable {
        let epoch: UInt32
        let seq: UInt64

        init(epoch: UInt32, seq: UInt64) {
            self.epoch = epoch
            self.seq = seq
        }

        init(_ header: EnvelopeHeader) {
            self.init(epoch: header.epoch, seq: header.seq)
        }

        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.epoch, lhs.seq) < (rhs.epoch, rhs.seq) }
    }

    private static let keyboxPrefix = "keybox-"

    /// Every verified version this replica accepted, per wire name: the
    /// DataZone rollback guard. Kept across deletions; dropped only by the
    /// format wipe, together with the rows the zone is then re-read into.
    static let dataSeenTableSQL = """
        CREATE TABLE IF NOT EXISTS data_seen (
            wire_name TEXT PRIMARY KEY,
            epoch INTEGER NOT NULL,
            seq INTEGER NOT NULL
        )
        """

    /// SQLite INTEGER is signed: a u64 seq is stored by bit pattern and
    /// compared in Swift after reading it back.
    private static func seenVersion(of wireName: String, in db: Database) throws -> RecordVersion? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT epoch, seq FROM data_seen WHERE wire_name = ?", arguments: [wireName]
        ) else { return nil }
        let epoch: Int64 = row["epoch"]
        let seq: Int64 = row["seq"]
        return RecordVersion(epoch: UInt32(truncatingIfNeeded: epoch), seq: UInt64(bitPattern: seq))
    }

    /// Callers checked `version` is above the stored mark.
    private static func recordSeen(_ wireName: String, version: RecordVersion, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO data_seen (wire_name, epoch, seq) VALUES (?, ?, ?)
                ON CONFLICT(wire_name) DO UPDATE SET epoch = excluded.epoch, seq = excluded.seq
                """,
            arguments: [wireName, Int64(version.epoch), Int64(bitPattern: version.seq)]
        )
    }

    /// A new version keeps the row's plain name and kind (the wire name is a
    /// keyed hash of exactly that kind and id, so they cannot change) and is
    /// marked for indexing again: `indexPending` reports it once it opens.
    private func upsert(_ item: VerifiedRecord, in db: Database) throws {
        let fixed = opener.fixedName(item.record.recordName)
        let version = item.version ?? RecordVersion(epoch: 0, seq: 0)
        try db.execute(
            sql: """
                INSERT INTO slice_records (record_name, plain_name, kind, epoch, seq, payload, modified_at, needs_index)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(record_name) DO UPDATE SET
                    plain_name = COALESCE(excluded.plain_name, slice_records.plain_name),
                    kind = COALESCE(excluded.kind, slice_records.kind),
                    epoch = excluded.epoch,
                    seq = excluded.seq,
                    payload = excluded.payload,
                    modified_at = excluded.modified_at,
                    needs_index = 1
                """,
            arguments: [
                item.record.recordName, fixed?.plainName, fixed?.kind,
                Int64(version.epoch), Int64(bitPattern: version.seq),
                item.record.payload, item.record.modifiedAt.timeIntervalSince1970
            ]
        )
    }

    // MARK: - Indexing

    /// Opens every unindexed row it can and fills `kind`/`plain_name`;
    /// returns the indexed records (for `onRecordsApplied`, F11:
    /// `recordName` = plain name, typed `SliceKind`, `notifyLevel` from the
    /// opened frame, `modifiedAt`; rows of an unknown kind are indexed but
    /// not surfaced). Rows that stay unopenable for `.locked` (or keys not
    /// here yet) stay unindexed and are not counted (F15); others are
    /// counted corrupt (or newer-format) and retried on the next pass.
    /// Opening happens outside the write transaction; a row replaced in
    /// between keeps its new version unindexed for the next pass.
    @discardableResult
    public func indexPending() throws -> [AppliedSliceRecord] {
        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT record_name, epoch, seq, payload, modified_at FROM slice_records
                    WHERE needs_index = 1 ORDER BY record_name
                    """
            )
        }
        var opened: [(row: Row, frame: InnerFrame)] = []
        for row in rows {
            if let frame = openRow(wireName: row["record_name"], payload: row["payload"]) {
                opened.append((row, frame))
            }
        }
        guard !opened.isEmpty else { return [] }
        return try writer.write { db -> [AppliedSliceRecord] in
            var indexed: [AppliedSliceRecord] = []
            for (row, frame) in opened {
                try db.execute(
                    sql: """
                        UPDATE slice_records SET plain_name = ?, kind = ?, needs_index = 0
                        WHERE record_name = ? AND epoch = ? AND seq = ? AND needs_index = 1
                        """,
                    arguments: [frame.id, frame.kind, row["record_name"] as String, row["epoch"] as Int64, row["seq"] as Int64]
                )
                guard db.changesCount > 0, let kind = SliceKind(rawValue: frame.kind) else { continue }
                indexed.append(AppliedSliceRecord(
                    recordName: frame.id, kind: kind, notifyLevel: frame.notifyLevel,
                    modifiedAt: Date(timeIntervalSince1970: row["modified_at"])
                ))
            }
            return indexed
        }
    }

    // MARK: - Opening

    /// The frame of one stored envelope, or nil when it does not open now.
    /// A locked keychain or keys not here yet: skipped, not counted (F15,
    /// F35). A newer format: counted as such. Anything else about the
    /// envelope: counted corrupt and logged once.
    private func openRow(wireName: String, payload: Data) -> InnerFrame? {
        do {
            return try opener.open(wireName: wireName, envelope: payload)
        } catch let error as EnvelopeError {
            if Self.isNewerFormat(error) {
                noteNewerFormat(wireName)
            } else {
                noteCorrupt([wireName], what: "envelope (\(Self.code(error)))")
            }
            return nil
        } catch KeyStoreError.locked {
            return nil
        } catch SecureTransportError.keysUnavailable {
            return nil
        } catch {
            // Not the row's fault (an unreadable keychain item, a bad hub id): skipped and logged once per cause.
            let cause = String(describing: error)
            if keyFailures.withLock({ $0.insert(cause).inserted }) {
                logger.error("replica keys unreadable, rows skipped: \(cause, privacy: .public)")
            }
            return nil
        }
    }

    /// The opened payload of one row for a single-record read: a locked
    /// keychain throws (locked is its own state, never "absent"); an
    /// envelope that does not open is counted and throws its error.
    private func openedPayload(wireName: String, payload: Data) throws -> Data {
        do {
            return try opener.open(wireName: wireName, envelope: payload).payload
        } catch let error as EnvelopeError {
            if Self.isNewerFormat(error) {
                noteNewerFormat(wireName)
            } else {
                noteCorrupt([wireName], what: "envelope (\(Self.code(error)))")
            }
            throw error
        }
    }

    private static func isNewerFormat(_ error: EnvelopeError) -> Bool {
        switch error {
        case .unsupportedVersion, .unsupportedSuite: return true
        default: return false
        }
    }

    /// A short code for logs (`signatureInvalid`, `wrongHub`, ...); never key material.
    private static func code(_ error: EnvelopeError) -> String {
        String(describing: error)
    }

    private func noteRejected(_ wireName: String, reason: String) {
        guard rejected.withLock({ $0.insert(wireName).inserted }) else { return }
        logger.warning("data record refused: \(wireName, privacy: .public): \(reason, privacy: .public)")
    }

    private func noteNewerFormat(_ wireName: String) {
        guard newerFormat.withLock({ $0.insert(wireName).inserted }) else { return }
        logger.notice("data record of a newer format kept unread: \(wireName, privacy: .public)")
    }

    /// Tracks distinct corrupt wire names and logs only on the first
    /// sighting of each — an observation-driven list refetches on every
    /// change, so a persistently-bad row must not re-log forever.
    private func noteCorrupt(_ wireNames: [String], what: String) {
        let names = wireNames // immutable copy for the @Sendable withLock closure
        let firstSeen = corrupt.withLock { seen -> [String] in
            names.filter { seen.insert($0).inserted }
        }
        for name in firstSeen {
            logger.warning("unreadable \(what, privacy: .public) skipped: \(name, privacy: .public)")
        }
    }

    /// Records refused at apply (bad signature, another hub, malformed, an
    /// older version), distinct wire names since init.
    public func rejectedCount() -> Int {
        rejected.withLock { $0.count }
    }

    /// Records of a newer envelope version or suite, distinct wire names
    /// since init: the phone shows "Update Watchtower on this iPhone".
    public func newerFormatCount() -> Int {
        newerFormat.withLock { $0.count }
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
    /// `updated_at`, or an envelope that does not open, reads as never seen
    /// (conservative) and is logged once. A locked keychain throws.
    public func heartbeatAge(now: Date = Date()) throws -> Duration? {
        let row = try writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT record_name, payload FROM slice_records WHERE plain_name = ?",
                arguments: [HeartbeatPayload.recordName]
            )
        }
        guard let row else { return nil }
        let payload: Data
        do {
            payload = try openedPayload(wireName: row["record_name"], payload: row["payload"])
        } catch is EnvelopeError {
            noteUndecodableHeartbeat()
            return nil
        }
        guard let stamp = try? RelayCoder.makeDecoder().decode(HeartbeatStamp.self, from: payload) else {
            noteUndecodableHeartbeat()
            return nil
        }
        return .seconds(now.timeIntervalSince(stamp.updatedAt))
    }

    private func noteUndecodableHeartbeat() {
        let firstTime = undecodableHeartbeatLogs.withLock { emitted -> Bool in
            guard emitted == 0 else { return false }
            emitted = 1
            return true
        }
        if firstTime {
            logger.warning("undecodable heartbeat payload, the Mac reads as offline")
        }
    }

    /// The opened payload of one data-zone record by its PLAIN name
    /// (`heartbeat`, `device_grant-<id>`), from an ALREADY-OPEN database so
    /// it runs inside a ValueObservation tracking closure; nil when the
    /// record is absent (or not indexed yet). A locked keychain throws
    /// `KeyStoreError.locked`, and an envelope that does not open throws its
    /// `EnvelopeError` (counted): absent, locked and unreadable stay apart.
    public func payload(forRecordName recordName: String, from db: Database) throws -> Data? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT record_name, payload FROM slice_records WHERE plain_name = ?",
            arguments: [recordName]
        ) else { return nil }
        return try openedPayload(wireName: row["record_name"], payload: row["payload"])
    }

    /// Every opened payload of one data-zone kind (the WatchtowerKit slice
    /// mirrors decode them), from an ALREADY-OPEN database so it runs inside
    /// a ValueObservation tracking closure. Ordered by plain record name. A
    /// row that does not open is skipped: counted corrupt, except while the
    /// keys are locked (not counted, F15/F35).
    public func payloads(of kind: SliceKind, from db: Database) throws -> [Data] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT record_name, payload FROM slice_records WHERE kind = ? ORDER BY plain_name",
            arguments: [kind.rawValue]
        )
        return rows.compactMap { row in openRow(wireName: row["record_name"], payload: row["payload"])?.payload }
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
    /// first. A row that does not open is skipped like an undecodable one,
    /// except while the keys are locked (skipped, not counted).
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
            let wireName: String = row["record_name"]
            guard let frame = openRow(wireName: wireName, payload: row["payload"]) else { continue }
            do {
                decoded.append(try T(row: RowPayloadCoder.row(from: frame.payload)))
            } catch {
                badNames.append(wireName)
            }
        }
        if !badNames.isEmpty {
            noteCorrupt(badNames, what: "\(kind.rawValue) payload")
        }
        return decoded
    }

    /// Number of DISTINCT wire names whose rows failed to open or decode
    /// across all reads and `indexPending` passes since init.
    public func corruptCount() -> Int {
        corrupt.withLock { $0.count }
    }
}
