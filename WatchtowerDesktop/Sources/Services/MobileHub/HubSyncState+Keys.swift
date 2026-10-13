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
/// - `pending_devices` (Task 13: `savePendingDevice`, `confirmPendingDevice`), `revoked_devices` (Task 14: a removed
///   phone's key, name and scope, for its `revoked` keybox, D9), `relay_seen` (the relay rollback guard, F3).
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
                removed_at REAL NOT NULL,
                name TEXT,
                scope TEXT
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
        try addMissingColumns("revoked_devices", [("name", "TEXT"), ("scope", "TEXT")], db)
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

    // MARK: - Rotation (Task 14, spec §2.2, D3, D9)

    /// Removes a linked device and rotates the epoch in one IMMEDIATE transaction (Review Focus 4): the device row
    /// goes with its refusal, pending request and `relay_seen` rows (`WHERE sender_id = ?`, F3); a device with an
    /// agreement key gets a `revoked_devices` row (its revoked keybox, D9); the current epoch is retired, `newEpoch`
    /// inserted and the slice hashes wiped (the relay token kept). nil, and nothing written, when the device is not
    /// linked. Throws, with nothing written, when `newEpoch` is not the epoch after the current one (another hub
    /// process rotated first) or the wipe fails.
    func removeDeviceAndRotate(
        _ deviceID: String, newEpoch: (epoch: UInt32, sealedKeys: Data), at date: Date
    ) throws -> LinkedDevice? {
        try writeKeys { db in
            guard let removed = try Self.removeDevice(deviceID, at: date, db) else { return nil }
            try Self.rotateEpoch(newEpoch, at: date, db)
            return removed
        }
    }

    /// The same rotation without a device (the cap, a suspected leak).
    func rotate(newEpoch: (epoch: UInt32, sealedKeys: Data), at date: Date) throws {
        try writeKeys { db in try Self.rotateEpoch(newEpoch, at: date, db) }
    }

    /// The removed device, nil when none is linked under that id (any case).
    private static func removeDevice(_ deviceID: String, at date: Date, _ db: Database) throws -> LinkedDevice? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID]) else { return nil }
        let removed = device(row)
        for table in ["devices", "link_refusals", "pending_devices", "revoked_devices"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
        }
        try db.execute(sql: "DELETE FROM relay_seen WHERE sender_id = ? COLLATE NOCASE", arguments: [deviceID])
        // A pre-E2E row has no key: no keybox can be sealed to it, so it gets no revoked one.
        if let agreementKey = row["agreement_key"] as Data? {
            try db.execute(
                sql: "INSERT INTO revoked_devices (device_id, name, scope, agreement_key, removed_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    removed.deviceID, removed.name, removed.scope.rawValue, agreementKey, date.timeIntervalSince1970
                ])
        }
        return removed
    }

    /// Retires the current epoch, inserts `newEpoch` (its first seq is the seq ceiling now) and wipes the slice
    /// hashes, in the caller's transaction. The epoch insert comes before the wipe.
    private static func rotateEpoch(_ newEpoch: (epoch: UInt32, sealedKeys: Data), at date: Date, _ db: Database) throws {
        guard let current = try latestEpochs(db).last else { throw SecureTransportError.keysUnavailable }
        let (next, overflow) = current.epoch.addingReportingOverflow(1)
        guard !overflow, newEpoch.epoch == next else { throw HubKeyringError.epochRaced(newEpoch.epoch) }
        try db.execute(
            sql: "UPDATE hub_epochs SET retired_at = ? WHERE epoch = ? AND retired_at IS NULL",
            arguments: [date.timeIntervalSince1970, Int64(current.epoch)])
        try insertEpoch(.init(
            epoch: next, sealedKeys: newEpoch.sealedKeys, createdAt: date,
            firstSeq: try HubKeyring.seqCeiling(metaValue(HubKeyring.seqCeilingKey, db)), retiredAt: nil), db)
        try wipeForRotation(db)
    }

    // MARK: - Revoked devices (D9)

    /// A phone removed on the Mac: its keybox reads `revoked` (no keys) for `DeviceGrantSlice.revokedLifetime`.
    struct RevokedDevice: Equatable, Sendable {
        let deviceID: String
        let name: String
        let scope: DeviceScope
        let removedAt: Date
    }

    /// Every revoked device, newest removal first.
    func revokedDevices() throws -> [RevokedDevice] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM revoked_devices ORDER BY removed_at DESC, device_id").map { row in
                RevokedDevice(
                    deviceID: row["device_id"], name: row["name"] ?? "",
                    scope: DeviceScope(rawValue: row["scope"] ?? DeviceScope.private.rawValue),
                    removedAt: Date(timeIntervalSince1970: row["removed_at"]))
            }
        }
    }

    func pruneRevokedDevices(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM revoked_devices WHERE removed_at <= ?", arguments: [date.timeIntervalSince1970])
        }
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

    // MARK: - Pending link requests (Task 13)

    /// A phone whose hello carried a valid code, waiting for the owner's Link or Refuse on the Mac. Its keys are
    /// public keys; `sas` is the four-digit code both screens show.
    struct PendingDevice: Equatable, Sendable {
        let deviceID: String
        let name: String
        let model: String
        let scope: DeviceScope
        let userRecordName: String
        let signingKey: Data
        let agreementKey: Data
        /// The QR nonce text of the code the hello was sealed under.
        let linkNonce: String
        let sas: String
        let receivedAt: Date
    }

    /// Stores a pending request; false (nothing written) when the same device already waits with the same code. The
    /// same device with another code replaces its request.
    @discardableResult
    func savePendingDevice(_ pending: PendingDevice) throws -> Bool {
        try queue.write { db in
            if let stored = try Row.fetchOne(
                db, sql: "SELECT link_nonce, signing_key, agreement_key FROM pending_devices WHERE device_id = ? COLLATE NOCASE",
                arguments: [pending.deviceID]),
               stored["link_nonce"] as String? == pending.linkNonce, stored["signing_key"] as Data? == pending.signingKey,
               stored["agreement_key"] as Data? == pending.agreementKey {
                return false
            }
            try db.execute(sql: "DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE", arguments: [pending.deviceID])
            try db.execute(
                sql: """
                    INSERT INTO pending_devices (device_id, name, model, scope, user_record_name, signing_key, agreement_key,
                                                 link_nonce, sas, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    pending.deviceID, pending.name, pending.model, pending.scope.rawValue, pending.userRecordName,
                    pending.signingKey, pending.agreementKey, pending.linkNonce, pending.sas,
                    pending.receivedAt.timeIntervalSince1970
                ])
            return true
        }
    }

    /// Every pending request, oldest first.
    func pendingDevices() throws -> [PendingDevice] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_devices ORDER BY received_at, device_id").compactMap(Self.pending)
        }
    }

    /// What the owner's Link did.
    enum ConfirmOutcome: Equatable, Sendable {
        /// No request waits for the device.
        case noRequest
        /// The request waiting now shows another code than the one the owner confirmed (it was replaced): nothing
        /// changed, the request waits for a fresh decision.
        case codeChanged
        case decided(PendingDevice, LinkDecision)
    }

    /// The owner clicked Link on the request showing `sas`: in one transaction the request must still show that
    /// code, then the link code is re-checked (`linkDevice`: it may have expired or been used meanwhile), a valid one
    /// links the phone with its keys and nonce, a refused one becomes a refusal sealed to the phone's key (F5), and
    /// the request goes.
    func confirmPendingDevice(_ deviceID: String, sas: String, now: Date) throws -> ConfirmOutcome {
        try writeKeys { db in
            guard let pending = try Self.pendingDevice(deviceID, db) else { return .noRequest }
            guard pending.sas == sas else { return .codeChanged }
            let device = LinkedDevice(
                deviceID: pending.deviceID, name: pending.name, scope: pending.scope,
                userRecordName: pending.userRecordName, linkedAt: now)
            let decision = try Self.linkDevice(device, nonce: pending.linkNonce, now: now, db)
            switch decision {
            case .valid:
                try db.execute(
                    sql: "UPDATE devices SET signing_key = ?, agreement_key = ?, link_nonce = ? WHERE device_id = ? COLLATE NOCASE",
                    arguments: [pending.signingKey, pending.agreementKey, pending.linkNonce, pending.deviceID])
            case .refused(let reason):
                try Self.refuse(pending, reason, at: now, db)
            case .alreadyUsedByThisDevice:
                break
            }
            try db.execute(sql: "DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE", arguments: [pending.deviceID])
            return .decided(pending, decision)
        }
    }

    /// Refuses one pending request with `reason` (the owner's Refuse: `not_confirmed`); the removed request, nil when
    /// none waited.
    @discardableResult
    func refusePendingDevice(_ deviceID: String, reason: LinkRefusal, at date: Date) throws -> PendingDevice? {
        try writeKeys { db in
            guard let pending = try Self.pendingDevice(deviceID, db) else { return nil }
            try Self.refuse(pending, reason, at: date, db)
            try db.execute(sql: "DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE", arguments: [pending.deviceID])
            return pending
        }
    }

    /// Refuses every pending request with `reason` (the link closed); how many there were.
    func refusePendingDevices(reason: LinkRefusal, at date: Date) throws -> Int {
        try writeKeys { db in
            let all = try Row.fetchAll(db, sql: "SELECT * FROM pending_devices").compactMap(Self.pending)
            for pending in all { try Self.refuse(pending, reason, at: date, db) }
            try db.execute(sql: "DELETE FROM pending_devices")
            return all.count
        }
    }

    /// A refusal sealed to the request's key, unless the phone is linked already (it keeps its link).
    private static func refuse(_ pending: PendingDevice, _ reason: LinkRefusal, at date: Date, _ db: Database) throws {
        let linked = try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM devices WHERE device_id = ? COLLATE NOCASE)", arguments: [pending.deviceID]
        ) ?? false
        guard !linked else { return }
        try saveLinkRefusal(LinkRefusalRecord(
            deviceID: pending.deviceID, name: pending.name, scope: pending.scope, reason: reason, at: date,
            agreementKey: pending.agreementKey), db)
    }

    private static func pendingDevice(_ deviceID: String, _ db: Database) throws -> PendingDevice? {
        try Row.fetchOne(db, sql: "SELECT * FROM pending_devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
            .flatMap(pending)
    }

    /// nil for a row missing a key column (never written so by `savePendingDevice`).
    private static func pending(_ row: Row) -> PendingDevice? {
        guard let signingKey = row["signing_key"] as Data?, let agreementKey = row["agreement_key"] as Data?,
              let nonce = row["link_nonce"] as String?, let sas = row["sas"] as String?,
              let receivedAt = row["received_at"] as Double? else { return nil }
        return PendingDevice(
            deviceID: row["device_id"], name: row["name"] ?? "", model: row["model"] ?? "",
            scope: DeviceScope(rawValue: row["scope"] ?? DeviceScope.private.rawValue),
            userRecordName: row["user_record_name"] ?? "", signingKey: signingKey, agreementKey: agreementKey,
            linkNonce: nonce, sas: sas, receivedAt: Date(timeIntervalSince1970: receivedAt))
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
