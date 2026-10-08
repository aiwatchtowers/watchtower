import Foundation
import GRDB
import WatchtowerSync

/// The hub's sidecar database (`hubstate.db`, mobile POC spec §3): what was
/// last pushed per DataZone record (`slice_state`), small hub values
/// (`hub_meta`) and the exactly-once ledger of relay records
/// (`relay_processed`, spec §5.2 rule 1).
/// Mirrors the TransportStore GRDB pattern: DatabaseQueue + `CREATE TABLE IF NOT EXISTS`.
final class HubSyncState: Sendable {
    /// Where one relay record stands in the exactly-once ledger.
    enum RelayPhase: String {
        /// Committed before a non-idempotent kind writes; still `begun` at
        /// a later pass means the hub stopped mid-apply.
        case begun
        /// Handled and echoed (or skipped for good); never handled again.
        case done
    }

    static let hubIDKey = "hub_id"
    private static let generationKey = "sync_generation"

    private let queue: DatabaseQueue
    /// One relay pass at a time over this ledger, whichever processor runs
    /// it (a rebuilt hub shares the sidecar with the one it replaces).
    let relayGate = RelayPassGate()

    init(path: String) throws {
        // A second handle on the file (a relaunch whose old instance is
        // still closing, a duplicate app instance) waits for the lock
        // instead of failing at once with SQLITE_BUSY.
        var config = Configuration()
        config.busyMode = .timeout(5)
        queue = try DatabaseQueue(path: path, configuration: config)
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
                    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
                    outcome TEXT,
                    updated_at REAL NOT NULL DEFAULT 0
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
                try db.execute(sql: "DELETE FROM slice_state WHERE record_name = ?", arguments: [name])
            }
        }
    }

    // MARK: - Hub meta (relay change token, hub id, …)

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

    /// This install's hub id (spec §4.1), created on first use and kept for
    /// good: an account reset does not change which Mac this is.
    func ensureHubID() throws -> String {
        try ensureMetaValue(forKey: Self.hubIDKey) { UUID().uuidString.lowercased() }
    }

    /// The value under `key`, or `make()` stored there when the key is new.
    /// One write transaction, so two callers never store two values.
    func ensureMetaValue(forKey key: String, make: () -> String) throws -> String {
        try queue.write { db in
            if let existing = try String.fetchOne(
                db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [key]
            ) {
                return existing
            }
            let fresh = make()
            try db.execute(sql: "INSERT INTO hub_meta (key, value) VALUES (?, ?)", arguments: [key, fresh])
            return fresh
        }
    }

    // MARK: - Relay exactly-once ledger (spec §5.2 rule 1)

    func relayPhase(_ recordName: String) throws -> RelayPhase? {
        try queue.read { db in
            let raw = try String.fetchOne(
                db,
                sql: "SELECT phase FROM relay_processed WHERE record_name = ?",
                arguments: [recordName]
            )
            return raw.flatMap(RelayPhase.init(rawValue:))
        }
    }

    /// The atomic `begun` claim of a non-idempotent kind, committed BEFORE
    /// it touches the main DB or a PTY: true only for the one caller whose
    /// insert created the row, so two passes can never both apply it.
    func claimRelay(_ recordName: String, at date: Date) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'begun', NULL, ?)
                    ON CONFLICT(record_name) DO NOTHING
                    """,
                arguments: [recordName, date.timeIntervalSince1970]
            )
            return db.changesCount > 0
        }
    }

    /// Marks a record `begun` whatever it held (tests seed an interrupted
    /// apply with it; the hub itself claims through `claimRelay`).
    func markRelayBegun(_ recordName: String, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'begun', NULL, ?)
                    ON CONFLICT(record_name) DO UPDATE SET phase = 'begun', updated_at = excluded.updated_at
                    """,
                arguments: [recordName, date.timeIntervalSince1970]
            )
        }
    }

    /// `outcome` is the echoed status (and reason, when there is one), for
    /// diagnostics only: a `done` record is skipped whatever it holds.
    func markRelayDone(_ recordName: String, outcome: String, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
                    VALUES (?, 'done', ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        phase = 'done', outcome = excluded.outcome, updated_at = excluded.updated_at
                    """,
                arguments: [recordName, outcome, date.timeIntervalSince1970]
            )
        }
    }

    /// Retention: drops ledger entries last touched before `date`. Safe
    /// because the cutoff lies past the relay max age: a re-delivered record
    /// that old fails the age check (`expired`) and is never applied, and an
    /// already-echoed record is skipped on its echo status first.
    func pruneRelayProcessed(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM relay_processed WHERE updated_at < ?",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }

    // MARK: - Account-change reset

    /// Clears the sync state derived from the CloudKit account so the next
    /// publish/relay cycle starts clean against the new account: slice
    /// hashes, the relay change token and the heartbeat read state (the new
    /// account's DataZone is another zone). The exactly-once ledger is KEPT:
    /// relay record names carry phone-generated UUIDs, so they cannot
    /// collide across accounts, and on a same-Apple-ID sign-out/sign-in the
    /// re-fetched zone still holds actions whose echo never reached the
    /// server — without the ledger they would be applied a second time
    /// (spec §8 I-3, §9). The hygiene stamp, the hub id and `enabled_at`
    /// are kept too.
    /// The generation counter is bumped so an in-flight publish cycle can
    /// detect the reset and abort before recording stale hashes.
    func wipeSyncState() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM slice_state")
            for key in [RelayProcessor.relayTokenKey] + HubIdentity.heartbeatReadKeys {
                try db.execute(sql: "DELETE FROM hub_meta WHERE key = ?", arguments: [key])
            }
            try db.execute(
                sql: """
                    INSERT INTO hub_meta (key, value)
                    VALUES (?, CAST(COALESCE((SELECT value FROM hub_meta WHERE key = ?), '0') AS INTEGER) + 1)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [Self.generationKey, Self.generationKey]
            )
        }
    }

    /// The sync generation counter: 0 until the first `wipeSyncState()`.
    func generation() throws -> Int {
        let raw = try metaValue(forKey: Self.generationKey)
        return raw.flatMap(Int.init) ?? 0
    }
}
