import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The E2E key tables of `hubstate.db` (D3, F3, F5, F19, F27). Every table here is created by `createSchema`,
/// whichever task writes it:
/// - `hub_epochs`: one row per epoch, `sealed_keys` = ChaChaPoly(wrap key, K_data ‖ K_alert); `hub_meta` keeps
///   `k_meta_sealed` and `envelope_seq_ceiling` (`HubKeyring`).
/// - `devices` + `signing_key`, `agreement_key`, `link_nonce` (the QR nonce text), `last_seq` (D4 diagnostics).
/// - `link_refusals` + `agreement_key`: the refused hello's key, so the refusal keybox can be sealed (F5).
/// - `slice_state` + `wire_name`: the opaque record name beside the plain one (F19, written by Task 11).
/// - `pending_devices` (Task 13), `revoked_devices` (Task 14), `relay_seen` (the relay rollback guard, F3).
/// No column holds a key in the clear: epoch keys and K_meta are sealed, the device columns are public keys.
extension HubSyncState {
    private static let keysLogger = Logger(subsystem: Constants.bundleID, category: "HubKeys")

    static func createKeyTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS hub_epochs (
                epoch INTEGER PRIMARY KEY,
                sealed_keys BLOB NOT NULL,
                created_at REAL NOT NULL,
                first_seq INTEGER NOT NULL,
                retired_at REAL
            );
            CREATE TABLE IF NOT EXISTS pending_devices (
                device_id TEXT PRIMARY KEY,
                name TEXT,
                model TEXT,
                scope TEXT,
                user_record_name TEXT,
                signing_key BLOB,
                agreement_key BLOB,
                link_nonce TEXT,
                sas TEXT,
                received_at REAL
            );
            CREATE TABLE IF NOT EXISTS revoked_devices (
                device_id TEXT PRIMARY KEY,
                agreement_key BLOB NOT NULL,
                removed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS relay_seen (
                wire_name TEXT NOT NULL,
                sender_id TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                at REAL NOT NULL,
                PRIMARY KEY (wire_name, sender_id)
            );
            """)
        // A sidecar from before E2E gains the columns; its rows hold none (a pre-E2E phone has no relay key and
        // re-pairs, spec §2.8).
        try addMissingColumns(
            "devices", [("signing_key", "BLOB"), ("agreement_key", "BLOB"), ("link_nonce", "TEXT"), ("last_seq", "INTEGER")], db)
        try addMissingColumns("link_refusals", [("agreement_key", "BLOB")], db)
        try addMissingColumns("slice_state", [("wire_name", "TEXT")], db)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS slice_state_by_wire ON slice_state (wire_name)")
    }

    private static func addMissingColumns(_ table: String, _ columns: [(String, String)], _ db: Database) throws {
        let existing = Set(try db.columns(in: table).map(\.name))
        for (name, type) in columns where !existing.contains(name) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(name) \(type)")
        }
    }

    /// One IMMEDIATE write transaction (the key writes read first, then write: two hub processes over one file take
    /// the lock in turn instead of failing the upgrade, and never fork an epoch).
    func writeKeys<T>(_ body: (Database) throws -> T) throws -> T {
        try queue.writeWithoutTransaction { db in
            var result: T?
            try db.inTransaction(.immediate) {
                result = try body(db)
                return .commit
            }
            // inTransaction runs the body or throws; a missing result cannot happen.
            guard let result else { throw DatabaseError(resultCode: .SQLITE_INTERNAL, message: "no transaction result") }
            return result
        }
    }

    /// True when the sidecar holds a pairing: a linked phone, an epoch or K_meta.
    func hasPairingState() throws -> Bool {
        try queue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM devices) OR EXISTS (SELECT 1 FROM hub_epochs)
                    OR EXISTS (SELECT 1 FROM hub_meta WHERE key = ?)
                """, arguments: [HubKeyring.metaKeySealedKey]) ?? false
        }
    }

    static func metaValue(_ key: String, _ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM hub_meta WHERE key = ?", arguments: [key])
    }

    static func setMetaValue(_ value: String, _ key: String, _ db: Database) throws {
        try db.execute(
            sql: "INSERT INTO hub_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value])
    }

    // MARK: - Epochs

    /// One `hub_epochs` row. `firstSeq` is the envelope seq ceiling when the epoch began: the seqs it used are at
    /// most `ceiling - firstSeq` plus one allocator block (spec §2.2's 2^28 cap is counted from it).
    struct StoredEpoch: Equatable, Sendable {
        let epoch: UInt32
        let sealedKeys: Data
        let createdAt: Date
        let firstSeq: UInt64
        let retiredAt: Date?
    }

    func storedEpoch(_ epoch: UInt32) throws -> StoredEpoch? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM hub_epochs WHERE epoch = ?", arguments: [Int64(epoch)]).map(Self.epoch)
        }
    }

    /// The newest two epochs, oldest first (the current one last): all the D10 relay window looks at.
    func latestEpochs() throws -> [StoredEpoch] {
        try queue.read { db in try Self.latestEpochs(db) }
    }

    static func latestEpochs(_ db: Database) throws -> [StoredEpoch] {
        try Row.fetchAll(db, sql: "SELECT * FROM hub_epochs ORDER BY epoch DESC LIMIT 2").map(epoch).reversed()
    }

    static func insertEpoch(_ epoch: StoredEpoch, _ db: Database) throws {
        try db.execute(
            sql: "INSERT INTO hub_epochs (epoch, sealed_keys, created_at, first_seq, retired_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                Int64(epoch.epoch), epoch.sealedKeys, epoch.createdAt.timeIntervalSince1970,
                Int64(bitPattern: epoch.firstSeq), epoch.retiredAt?.timeIntervalSince1970
            ])
    }

    private static func epoch(_ row: Row) -> StoredEpoch {
        StoredEpoch(
            epoch: UInt32(truncatingIfNeeded: row["epoch"] as Int64),
            sealedKeys: row["sealed_keys"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            firstSeq: UInt64(bitPattern: row["first_seq"] as Int64),
            retiredAt: (row["retired_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: - Device keys

    /// A linked phone's relay material: its public agreement key and the link nonce (QR text) it linked with.
    struct DeviceKeyRow: Equatable, Sendable {
        let deviceID: String
        let agreementKey: Data
        let linkNonce: String
    }

    /// Every linked phone that has relay material (a pre-E2E row has none).
    func deviceKeyRows() throws -> [DeviceKeyRow] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT device_id, agreement_key, link_nonce FROM devices
                WHERE agreement_key IS NOT NULL AND link_nonce IS NOT NULL ORDER BY linked_at, device_id
                """)
            return rows.map(Self.deviceKeyRow)
        }
    }

    /// Device ids are UUID text; a lookup ignores case (rows written by older builds kept the phone's spelling).
    func deviceKeyRow(_ deviceID: String) throws -> DeviceKeyRow? {
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT device_id, agreement_key, link_nonce FROM devices
                WHERE device_id = ? COLLATE NOCASE AND agreement_key IS NOT NULL AND link_nonce IS NOT NULL
                """, arguments: [deviceID])
            return row.map(Self.deviceKeyRow)
        }
    }

    private static func deviceKeyRow(_ row: Row) -> DeviceKeyRow {
        DeviceKeyRow(deviceID: row["device_id"], agreementKey: row["agreement_key"], linkNonce: row["link_nonce"])
    }

    /// The agreement key a keybox for `deviceID` is sealed to: a linked phone's, else a pending (Task 13), a
    /// revoked (Task 14) or a refused (F5) one's. nil when none of them holds a key for it.
    func keyboxRecipientKey(_ deviceID: String) throws -> Data? {
        try queue.read { db in
            for table in ["devices", "pending_devices", "revoked_devices", "link_refusals"] {
                if let key = try Data.fetchOne(
                    db, sql: "SELECT agreement_key FROM \(table) WHERE device_id = ? COLLATE NOCASE AND agreement_key IS NOT NULL",
                    arguments: [deviceID]) {
                    return key
                }
            }
            return nil
        }
    }

    // MARK: - Relay seq high-water mark (D4)

    /// The highest envelope seq a linked phone's relay records carried; nil before the first one. Diagnostics only:
    /// D4 gates replays with the ledger, the authenticated age and the rollback guard, never with this mark.
    func deviceLastSeq(_ deviceID: String) throws -> UInt64? {
        try queue.read { db in
            let stored = try Int64.fetchOne(
                db, sql: "SELECT last_seq FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
            return stored.map { UInt64(bitPattern: $0) }
        }
    }

    /// `last_seq = max(last_seq, seq)` for a linked phone (no row: nothing). Stored by bit pattern, compared here.
    func raiseDeviceLastSeq(_ deviceID: String, to seq: UInt64) throws {
        try queue.write { db in
            let stored = try Row.fetchOne(
                db, sql: "SELECT last_seq FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
            guard let stored else { return }
            if let current = stored["last_seq"] as Int64?, UInt64(bitPattern: current) >= seq { return }
            try db.execute(
                sql: "UPDATE devices SET last_seq = ? WHERE device_id = ? COLLATE NOCASE",
                arguments: [Int64(bitPattern: seq), deviceID])
        }
    }

    // MARK: - Relay rollback guard (F3)

    /// The highest (epoch, seq) recorded for one relay wire name and sender; nil when none was.
    func relaySeen(wireName: String, senderID: String) throws -> (epoch: UInt32, seq: UInt64)? {
        try queue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT epoch, seq FROM relay_seen WHERE wire_name = ? AND sender_id = ?",
                arguments: [wireName, senderID])
            return row.map { (UInt32(truncatingIfNeeded: $0["epoch"] as Int64), UInt64(bitPattern: $0["seq"] as Int64)) }
        }
    }

    /// Stores (epoch, seq) when it is newer than the stored version; never lowers it. Seqs are u64 on the wire, so
    /// they are stored by bit pattern and compared here, not in SQL.
    func recordRelaySeen(wireName: String, senderID: String, epoch: UInt32, seq: UInt64, at date: Date) throws {
        try queue.write { db in
            if let stored = try Row.fetchOne(
                db, sql: "SELECT epoch, seq FROM relay_seen WHERE wire_name = ? AND sender_id = ?",
                arguments: [wireName, senderID]) {
                let storedVersion = (UInt32(truncatingIfNeeded: stored["epoch"] as Int64), UInt64(bitPattern: stored["seq"] as Int64))
                guard (epoch, seq) > storedVersion else { return }
            }
            try db.execute(
                sql: """
                    INSERT INTO relay_seen (wire_name, sender_id, epoch, seq, at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(wire_name, sender_id) DO UPDATE SET epoch = excluded.epoch, seq = excluded.seq, at = excluded.at
                    """,
                arguments: [wireName, senderID, Int64(epoch), Int64(bitPattern: seq), date.timeIntervalSince1970])
        }
    }
}

/// F19: the persisted wire → plain name map over `slice_state.wire_name`, passed to the hub's `SecureTransport`.
extension HubSyncState: WireNameIndex {
    func plainName(forWire wireName: String) -> String? {
        do {
            return try queue.read { db in
                try String.fetchOne(db, sql: "SELECT record_name FROM slice_state WHERE wire_name = ?", arguments: [wireName])
            }
        } catch {
            // The protocol has no error path: the caller then falls back to its in-process map.
            Self.keysLogger.error(
                "wire name lookup failed for \(wireName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
