import CloudKit
import Foundation
import GRDB
import WatchtowerSync

/// The linking state of `hubstate.db` (spec §2.3, §10): the issued QR codes (`link_codes`), the linked phones
/// (`devices`) and the refused link attempts (`link_refusals`). The E2E pairing tables are in `HubSyncState+Keys.swift`.
extension HubSyncState {
    /// One QR code the hub issued. Single use: `usedByDevice` is set once.
    struct LinkCode: Equatable, Sendable {
        let nonce: String
        let issuedAt: Date
        let exp: Date
        let usedByDevice: String?
    }

    /// One linked phone (the `devices` table, spec §10).
    struct LinkedDevice: Equatable, Sendable {
        let deviceID: String
        /// At most `DevicePayload.maxNameLength` grapheme clusters.
        let name: String
        let scope: DeviceScope
        /// `shared`: the phone's own iCloud user. `private`: the Mac's own user (the hub owner), looked up at the
        /// hello, never the name the phone sent; empty when the lookup failed (only `CKCurrentUserDefaultName` then
        /// passes `accepts`).
        let userRecordName: String
        let linkedAt: Date
        var typingAllowed = false
        /// The phone's own "Start sessions" toggle, mirrored from its
        /// `device` record: the phone's opt-out, never a grant (#565).
        var startSessionsAllowed = true
        /// The owner's Allow of starting sessions from this phone (#565,
        /// `start_sessions_granted`): off until allowed in Settings →
        /// Mobile. It counts only with typing allowed (`mayStartSessions`).
        var startSessionsGranted = false
        /// When the owner last changed a grant; nil while undecided.
        var decidedAt: Date?
        /// The phone's own "Type into sessions" toggle (its `device`
        /// record's `typing_requested`): Settings → Mobile asks the owner to
        /// Allow it. Never a grant by itself.
        var typingRequested = false
        /// The owner's separate grant to answer Claude Code permission
        /// prompts from this phone (#517, spec §5.1): never implied by
        /// typing, and it does not imply typing.
        var permissionsAllowed = false
        /// The phone's own "Answer permission prompts from this phone"
        /// toggle (its `device` record's `permissions_requested`): Settings →
        /// Mobile asks the owner to Allow it. Never a grant by itself.
        var permissionsRequested = false

        /// Whether a `session_start` from this phone may go (#565): the
        /// owner allowed starting sessions and typing (a started agent reads
        /// the target text the phone wrote), and the phone has not turned
        /// its own toggle off.
        var mayStartSessions: Bool { startSessionsGranted && typingAllowed && startSessionsAllowed }

        /// The device gate's creator check (spec §5.2 rule 4): in `shared`
        /// scope a record must be written by the phone's own iCloud user.
        /// A `private` phone writes as the Mac's user, which CloudKit reports
        /// as `CKCurrentUserDefaultName` (or the owner's own name, stored as
        /// `userRecordName` at the link); nil is a record whose creator is
        /// unknown (the in-memory transport, an event buffered before
        /// creators were kept): `private` only.
        func accepts(creator: String?) -> Bool {
            if scope == .shared { return creator == userRecordName }
            guard let creator else { return true }
            return creator == CKCurrentUserDefaultName || (!userRecordName.isEmpty && creator == userRecordName)
        }
    }

    /// A refused link attempt, published as `device_grant` with `link_refused`.
    struct LinkRefusalRecord: Equatable, Sendable {
        let deviceID: String
        let name: String
        let scope: DeviceScope
        let reason: LinkRefusal
        let at: Date
        /// The refused hello's agreement key: the refusal keybox is sealed to it (F5). nil for a refusal from
        /// before E2E.
        var agreementKey: Data?
    }

    /// What a nonce does for a device.
    enum LinkDecision: Equatable, Sendable {
        /// Known, unused and `exp ≥ now`.
        case valid
        /// The same nonce from the same device again (idempotent).
        case alreadyUsedByThisDevice
        case refused(LinkRefusal)

        static func of(_ code: LinkCode?, deviceID: String, now: Date) -> Self {
            guard let code else { return .refused(.unknownCode) }
            if let used = code.usedByDevice {
                // Ids are UUID text whose spelling may differ (`linkDevice` keeps the stored row's).
                return used.caseInsensitiveCompare(deviceID) == .orderedSame ? .alreadyUsedByThisDevice : .refused(.usedCode)
            }
            return code.exp >= now ? .valid : .refused(.expiredCode)
        }
    }

    /// Stores a fresh code, then keeps the newest `keeping` codes. With
    /// `retiringOpenCodesAt`, every unused code still valid then is retired
    /// first (its `exp` set just before that moment), so only the new code
    /// links and a phone scanning an older one reads `expired_code`.
    func addLinkCode(nonce: String, issuedAt: Date, exp: Date, keeping: Int, retiringOpenCodesAt retiredAt: Date? = nil) throws {
        try queue.write { db in
            if let retiredAt {
                try db.execute(
                    sql: "UPDATE link_codes SET exp = ? WHERE used_by_device IS NULL AND exp >= ?",
                    arguments: [retiredAt.timeIntervalSince1970 - 1, retiredAt.timeIntervalSince1970]
                )
            }
            try db.execute(
                sql: "INSERT INTO link_codes (nonce, issued_at, exp) VALUES (?, ?, ?)",
                arguments: [nonce, issuedAt.timeIntervalSince1970, exp.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    DELETE FROM link_codes WHERE nonce NOT IN (
                        SELECT nonce FROM link_codes ORDER BY issued_at DESC, rowid DESC LIMIT ?
                    )
                    """,
                arguments: [keeping]
            )
        }
    }

    /// Retires one code at `retiredAt` (its `exp` set just before it) unless it is used or already past: a hello
    /// under it is refused from then on.
    func retireLinkCode(_ nonce: String, at retiredAt: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE link_codes SET exp = ? WHERE nonce = ? AND used_by_device IS NULL AND exp >= ?",
                arguments: [retiredAt.timeIntervalSince1970 - 1, nonce, retiredAt.timeIntervalSince1970 - 1]
            )
        }
    }

    func linkCode(_ nonce: String) throws -> LinkCode? {
        try queue.read { try Self.fetchLinkCode(nonce, $0) }
    }

    /// Every stored code, newest first.
    func linkCodes() throws -> [LinkCode] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM link_codes ORDER BY issued_at DESC, rowid DESC").map(Self.linkCode)
        }
    }

    /// Links `device` with `nonce` in one transaction: the decision is
    /// re-checked there, and only a `.valid` one marks the code used by the
    /// device, upserts its row (a re-link keeps the owner's grants) and
    /// forgets its refusal, its revoked keybox, its relay rollback marks and
    /// its `last_seq`. Returns the decision it found.
    func linkDevice(_ device: LinkedDevice, nonce: String, now: Date) throws -> LinkDecision {
        try queue.write { db in try Self.linkDevice(device, nonce: nonce, now: now, db) }
    }

    /// `linkDevice` inside the caller's transaction.
    static func linkDevice(_ device: LinkedDevice, nonce: String, now: Date, _ db: Database) throws -> LinkDecision {
        let decision = LinkDecision.of(try fetchLinkCode(nonce, db), deviceID: device.deviceID, now: now)
        guard decision == .valid else { return decision }
        // A re-link keeps the row's own spelling: ids match ignoring case (`linkedDevice`), the key does not.
        let deviceID = try String.fetchOne(
            db, sql: "SELECT device_id FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [device.deviceID]
        ) ?? device.deviceID
        try db.execute(
            sql: "UPDATE link_codes SET used_by_device = ?, used_at = ? WHERE nonce = ?",
            arguments: [deviceID, now.timeIntervalSince1970, nonce]
        )
        try db.execute(
            sql: """
                INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, typing_allowed,
                                     start_sessions_allowed, decided_at, typing_requested)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    name = excluded.name, scope = excluded.scope,
                    user_record_name = excluded.user_record_name, linked_at = excluded.linked_at,
                    typing_requested = excluded.typing_requested
                """,
            arguments: [
                deviceID, device.name, device.scope.rawValue, device.userRecordName,
                device.linkedAt.timeIntervalSince1970, device.typingAllowed, device.startSessionsAllowed,
                device.decidedAt?.timeIntervalSince1970, device.typingRequested
            ]
        )
        try db.execute(sql: "DELETE FROM link_refusals WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
        // Linked again: its revoked keybox gives way to the linked one.
        try db.execute(sql: "DELETE FROM revoked_devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
        // A re-link (a reinstall, a lost seq floor) restarts the phone's seqs under the same epoch: its old
        // rollback marks would refuse its fixed-name records as `.older`. They protect nothing any more, because
        // the re-link replaces the link nonce its relay keys derive from (final review Kit I2 / Desktop I-1).
        try db.execute(sql: "DELETE FROM relay_seen WHERE sender_id = ? COLLATE NOCASE", arguments: [deviceID])
        try db.execute(sql: "UPDATE devices SET last_seq = NULL WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
        return .valid
    }

    /// Device ids are UUID text; the lookup ignores case, like the key rows (`deviceKeyRow`).
    func linkedDevice(_ deviceID: String) throws -> LinkedDevice? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
                .map(Self.device)
        }
    }

    /// Every linked phone, oldest link first (two phones of one name are
    /// told apart by `linkedAt`).
    func linkedDevices() throws -> [LinkedDevice] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM devices ORDER BY linked_at, device_id").map(Self.device)
        }
    }

    /// Whether any phone is linked (the publisher's and the CLI
    /// companions' gate: nothing but `device_grant` is published without one).
    func hasLinkedDevice() throws -> Bool {
        try queue.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM devices)") ?? false }
    }

    /// Deletes the device's row and refusal; the removed row, nil when it
    /// was not linked. Ids match ignoring case, like `linkedDevice`: a
    /// differently spelled id never leaves a removed phone linked.
    func removeLinkedDevice(_ deviceID: String) throws -> LinkedDevice? {
        try queue.write { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM devices WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
            try db.execute(sql: "DELETE FROM link_refusals WHERE device_id = ? COLLATE NOCASE", arguments: [deviceID])
            return row.map(Self.device)
        }
    }

    /// A grant the owner decides per phone (spec §10).
    enum DeviceGrantKind: String {
        case typing = "typing_allowed"
        /// The phone's own toggle, mirrored (not the owner's decision).
        case startSessions = "start_sessions_allowed"
        case startSessionsGrant = "start_sessions_granted"
        case permissions = "permissions_allowed"
    }

    /// Sets one grant of a linked device and stamps `decided_at`. False
    /// when the device is not linked.
    func setDeviceGrant(_ grant: DeviceGrantKind, _ allowed: Bool, deviceID: String, at date: Date) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE devices SET \(grant.rawValue) = ?, decided_at = ? WHERE device_id = ? COLLATE NOCASE",
                arguments: [allowed, date.timeIntervalSince1970, deviceID]
            )
            return db.changesCount > 0
        }
    }

    /// Stores the phone's typing request (not a grant, no `decided_at`).
    /// False when the device is not linked or the value did not change.
    func setTypingRequested(_ requested: Bool, deviceID: String) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE devices SET typing_requested = ? WHERE device_id = ? COLLATE NOCASE AND typing_requested != ?",
                arguments: [requested, deviceID, requested]
            )
            return db.changesCount > 0
        }
    }

    /// Stores the phone's request to answer permission prompts (not a
    /// grant, no `decided_at`). False when the device is not linked or the
    /// value did not change.
    func setPermissionsRequested(_ requested: Bool, deviceID: String) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE devices SET permissions_requested = ?
                    WHERE device_id = ? COLLATE NOCASE AND permissions_requested != ?
                    """,
                arguments: [requested, deviceID, requested]
            )
            return db.changesCount > 0
        }
    }

    /// Stores a linked phone's new name (its own rewrite after a rename). False when the device is not linked or
    /// the name did not change.
    func setDeviceName(_ name: String, deviceID: String) throws -> Bool {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE devices SET name = ? WHERE device_id = ? COLLATE NOCASE AND name != ?",
                arguments: [name, deviceID, name]
            )
            return db.changesCount > 0
        }
    }

    func saveLinkRefusal(_ refusal: LinkRefusalRecord) throws {
        try queue.write { db in try Self.saveLinkRefusal(refusal, db) }
    }

    /// `saveLinkRefusal` inside the caller's transaction. A refusal without an agreement key keeps the one stored.
    static func saveLinkRefusal(_ refusal: LinkRefusalRecord, _ db: Database) throws {
        // One refusal per phone whatever the id's spelling (the upsert key is case-sensitive).
        try db.execute(
            sql: "DELETE FROM link_refusals WHERE device_id = ? COLLATE NOCASE AND device_id != ?",
            arguments: [refusal.deviceID, refusal.deviceID])
        try db.execute(
            sql: """
                INSERT INTO link_refusals (device_id, name, scope, reason, at, agreement_key) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    name = excluded.name, scope = excluded.scope, reason = excluded.reason, at = excluded.at,
                    agreement_key = COALESCE(excluded.agreement_key, link_refusals.agreement_key)
                """,
            arguments: [
                refusal.deviceID, refusal.name, refusal.scope.rawValue, refusal.reason.rawValue,
                refusal.at.timeIntervalSince1970, refusal.agreementKey
            ]
        )
    }

    /// Every remembered refusal, newest first.
    func linkRefusals() throws -> [LinkRefusalRecord] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM link_refusals ORDER BY at DESC, device_id").map { row in
                LinkRefusalRecord(
                    deviceID: row["device_id"], name: row["name"], scope: DeviceScope(rawValue: row["scope"]),
                    reason: LinkRefusal(rawValue: row["reason"]), at: Date(timeIntervalSince1970: row["at"]),
                    agreementKey: row["agreement_key"]
                )
            }
        }
    }

    func pruneLinkRefusals(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM link_refusals WHERE at < ?", arguments: [date.timeIntervalSince1970])
        }
    }

    /// The hub's zones were deleted (multi-hub spec §3.3): forgets every
    /// code, linked phone, pending link request, refusal and revoked phone,
    /// and the lines held for those phones (their records went with the zones).
    func clearLinkState() throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM link_codes; DELETE FROM devices; DELETE FROM pending_devices; DELETE FROM link_refusals;
                    DELETE FROM revoked_devices; DELETE FROM held_session_lines
                    """)
        }
    }

    static func fetchLinkCode(_ nonce: String, _ db: Database) throws -> LinkCode? {
        try Row.fetchOne(db, sql: "SELECT * FROM link_codes WHERE nonce = ?", arguments: [nonce]).map(linkCode)
    }

    private static func linkCode(_ row: Row) -> LinkCode {
        LinkCode(
            nonce: row["nonce"],
            issuedAt: Date(timeIntervalSince1970: row["issued_at"]),
            exp: Date(timeIntervalSince1970: row["exp"]),
            usedByDevice: row["used_by_device"]
        )
    }

    static func device(_ row: Row) -> LinkedDevice {
        LinkedDevice(
            deviceID: row["device_id"],
            name: row["name"],
            scope: DeviceScope(rawValue: row["scope"]),
            userRecordName: row["user_record_name"],
            linkedAt: Date(timeIntervalSince1970: row["linked_at"]),
            typingAllowed: row["typing_allowed"],
            startSessionsAllowed: row["start_sessions_allowed"],
            startSessionsGranted: row["start_sessions_granted"],
            decidedAt: (row["decided_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            typingRequested: row["typing_requested"],
            permissionsAllowed: row["permissions_allowed"],
            permissionsRequested: row["permissions_requested"]
        )
    }
}
