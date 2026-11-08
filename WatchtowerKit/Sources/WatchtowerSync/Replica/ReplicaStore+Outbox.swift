import Foundation
import GRDB

// MARK: - The ordered outbox (relay client Phase 1)
//
// For a hub whose grant carries `ordered_actions`, `pending_actions` is a real outbox: each row has its gapless
// `action_seq`, the envelope epoch it was sealed in, the version of the phone's own last write (`record_seq`)
// and where it stands on its way to the hub (`delivery`). A legacy row keeps all of these NULL and today's path.
// The queued control records and the ids of the hub's handled controls live beside it. Like `pending_actions`,
// none of it is dropped by the format wipe, and only sealed envelopes and ids/counters/states/times are kept.

/// Where an ordered action stands: `queued` (not written, or put back by `resend_from`), `sent` (written, no
/// final echo yet), `settled` (a final echo arrived), `undelivered` (listed under Not delivered).
public enum Delivery: String, Sendable {
    case queued, sent, settled, undelivered
}

/// Why a row is listed under Not delivered: the transport refused its write for good, it was withdrawn after
/// 24 h without an answer, or the hub runs over Relay, which this phone cannot follow (R32, relay client Phase 3). A
/// row already listed keeps its first reason.
public enum UndeliveredReason: String, Sendable {
    case refused
    case noAnswer = "no_answer"
    case hubOnRelay = "hub_on_relay"
}

/// One ordered row as the flush reads it: the sealed envelope under its wire name, nothing in plaintext.
public struct OutboxRow: Equatable, Sendable {
    public let actionID: String
    public let actionSeq: UInt64
    public let epoch: UInt32
    public let wireName: String
    public let envelope: Data
    public let delivery: Delivery
    public let recordSeq: UInt64?
    public let sentAt: Date?
    public let createdAt: Date
}

/// A sealed control record waiting to be written (`skip_to`, say).
public struct QueuedControl: Equatable, Sendable {
    public let id: String
    public let kind: ControlKind
    public let wireName: String
    public let envelope: Data
    public let queuedAt: Date
}

enum ReplicaOutboxError: Error, Equatable {
    /// `replica_meta.action_seq_next` holds something that is not a seq: the counter cannot be trusted.
    case unreadableCounter(String)
    /// `setDelivery(.undelivered, …)`: a row is listed only through `markUndelivered`, with its reason and message.
    case undeliveredNeedsAReason
}

extension ReplicaStore {
    static let orderedActionsKey = "ordered_actions"
    static let actionSeqNextKey = "action_seq_next"
    /// The highest epoch an `epoch_ack` was queued for (relay client Phase 3): a lower or equal one never is.
    static let epochAckKey = "epoch_ack_epoch"
    /// How long a handled hub control id is remembered (sim "Bounded state").
    static let handledControlRetention: TimeInterval = 15 * 86_400

    /// The ordered columns of `pending_actions`, NULL on a legacy row.
    static let outboxColumns: [(name: String, type: String)] = [
        ("action_seq", "INTEGER"),
        ("epoch", "INTEGER"),
        ("record_seq", "INTEGER"),
        ("sent_at", "REAL"),
        ("delivery", "TEXT CHECK(delivery IN ('queued','sent','settled','undelivered'))"),
        ("undelivered_reason", "TEXT CHECK(undelivered_reason IN ('refused','no_answer','hub_on_relay'))")
    ]

    static var outboxColumnsSQL: String {
        outboxColumns.map { "\($0.name) \($0.type)" }.joined(separator: ",\n")
    }

    static let outboxTablesSQL = """
        CREATE TABLE IF NOT EXISTS outbound_controls (
            position INTEGER PRIMARY KEY AUTOINCREMENT,
            control_id TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            wire_name TEXT NOT NULL,
            envelope BLOB NOT NULL,
            queued_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS handled_controls (
            control_id TEXT PRIMARY KEY,
            handled_at REAL NOT NULL
        )
        """

    /// Adds the ordered columns to an overlay from before the outbox, in place, and the unique `action_seq` index.
    func upgradeOutboxColumns(_ db: Database, existing: [String]) throws {
        for column in Self.outboxColumns where !existing.contains(column.name) {
            try db.execute(sql: "ALTER TABLE pending_actions ADD COLUMN \(column.name) \(column.type)")
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_actions_action_seq
            ON pending_actions(action_seq) WHERE action_seq IS NOT NULL
            """)
    }

    // MARK: Flag and counter

    /// Whether this replica's hub runs ordered actions (`replica_meta.ordered_actions` = "1").
    func orderedActionsEnabled() throws -> Bool {
        try writer.read { db in try Self.meta(db, Self.orderedActionsKey) } == "1"
    }

    /// Turns ordered actions on for good (Ruling 3: sticky, never turned off by a later grant).
    func enableOrderedActions() throws {
        try writer.write { db in try Self.setMeta(db, Self.orderedActionsKey, "1") }
    }

    /// The seq the next ordered action gets: 1 when none was drawn yet.
    func nextActionSeq() throws -> UInt64 {
        try writer.read { db in try Self.nextActionSeq(db) }
    }

    /// Inserts the row (`queued`, its epoch) and moves the counter from `seq` to `seq + 1` only if it still reads
    /// `seq`; false = lost the race, nothing written.
    func insertOrderedAction(
        _ action: ActionRequestPayload, entityRecordName: String?, sealed: CloudRecord, epoch: UInt32, seq: UInt64
    ) throws -> Bool {
        try writer.write { db in
            guard try Self.nextActionSeq(db) == seq else { return false }
            try db.execute(
                sql: """
                    INSERT INTO pending_actions
                        (action_id, kind, entity_record_name, payload, wire_name, created_at, state,
                         action_seq, epoch, delivery)
                    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, 'queued')
                    """,
                arguments: [
                    action.id, action.kind.rawValue, entityRecordName, sealed.payload, sealed.recordName,
                    action.createdAt.timeIntervalSince1970, Int64(clamping: seq), Int64(epoch)
                ])
            try Self.setMeta(db, Self.actionSeqNextKey, String(seq + 1))
            return true
        }
    }

    // MARK: Rows

    /// The ordered rows in the given states, by `action_seq`.
    func outboxRows(_ deliveries: Set<Delivery>) throws -> [OutboxRow] {
        guard !deliveries.isEmpty else { return [] }
        let states = deliveries.map(\.rawValue)
        return try fetchOutboxRows(
            where: "action_seq IS NOT NULL AND delivery IN (\(Self.placeholders(states.count)))",
            arguments: StatementArguments(states))
    }

    /// The ordered rows with `fromSeq <= action_seq < below`, in any state, by `action_seq`.
    func outboxRows(fromSeq: UInt64, below: UInt64) throws -> [OutboxRow] {
        try fetchOutboxRows(
            where: "action_seq >= ? AND action_seq < ?", arguments: [Int64(clamping: fromSeq), Int64(clamping: below)])
    }

    /// A written row: `sent` with the version of its write. Only a `queued` row moves — a row a `resend_from`
    /// requeued meanwhile, or one an echo settled, is left as it is.
    func markSent(actionID: String, recordSeq: UInt64?, at date: Date) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE pending_actions SET delivery = 'sent', record_seq = ?, sent_at = ?
                    WHERE action_id = ? AND delivery = 'queued'
                    """,
                arguments: [recordSeq.map { Int64(clamping: $0) }, date.timeIntervalSince1970, actionID])
        }
    }

    /// The flush rewrote a held echo with the action (Task 6): the version of that write. A `queued` or `sent` row
    /// moves to `sent`; a row an echo settled or listed meanwhile is left as it is.
    func markRewritten(actionID: String, recordSeq: UInt64, at date: Date) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE pending_actions SET delivery = 'sent', record_seq = ?, sent_at = ?
                    WHERE action_id = ? AND delivery IN ('queued','sent')
                    """,
                arguments: [Int64(clamping: recordSeq), date.timeIntervalSince1970, actionID])
        }
    }

    /// Whether the overlay row `id` is an ordered one (`action_seq` set); false for a legacy or unknown id.
    func isOrderedAction(id: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT action_seq IS NOT NULL FROM pending_actions WHERE action_id = ?", arguments: [id])
        } ?? false
    }

    /// The hub's `applied` echo of an ordered row, in any delivery state (it is the hub's word, not a Dismiss): the
    /// row goes. Legacy rows and unknown ids are left alone. Returns whether a row went.
    func removeAppliedAction(id: String) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM pending_actions WHERE action_id = ? AND action_seq IS NOT NULL", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// The hub's `failed`/`expired`/`cancelled` echo of an ordered row, in any delivery state: `settled` and
    /// `failed` with the echo's message, reason and result; a Not delivered row leaves the list (its reason goes).
    func settleFailedAction(
        id: String, errorMessage: String, reason: ActionReason?, result: [String: JSONValue]?
    ) throws {
        let resultData = try result.map { try JSONEncoder().encode($0) }
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE pending_actions SET state = 'failed', error_message = ?, reason = ?, result = ?,
                        delivery = 'settled', undelivered_reason = NULL
                    WHERE action_id = ? AND action_seq IS NOT NULL
                    """,
                arguments: [errorMessage, reason?.rawValue, resultData, id])
        }
    }

    /// Sets the delivery of ordered rows (legacy rows are never touched). Refuses `.undelivered` (that is
    /// `markUndelivered`'s, with its reason). A row leaving Not delivered is pending again: its reason and the
    /// local message go.
    func setDelivery(_ delivery: Delivery, actionIDs: [String]) throws {
        guard delivery != .undelivered else { throw ReplicaOutboxError.undeliveredNeedsAReason }
        guard !actionIDs.isEmpty else { return }
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE pending_actions SET
                        state = CASE WHEN delivery = 'undelivered' THEN 'pending' ELSE state END,
                        error_message = CASE WHEN delivery = 'undelivered' THEN NULL ELSE error_message END,
                        undelivered_reason = NULL,
                        delivery = ?
                    WHERE action_seq IS NOT NULL AND action_id IN (\(Self.placeholders(actionIDs.count)))
                    """,
                arguments: StatementArguments([delivery.rawValue] + actionIDs))
        }
    }

    /// Sim rule 14: a `queued` row resealed under a newer epoch takes the new envelope and its epoch; its wire name,
    /// `action_seq` and `record_seq` (the version the overwrite goes under) stay. Any other state is left alone.
    /// Returns whether exactly one row took it.
    func replaceOutboxEnvelope(actionID: String, envelope: Data, epoch: UInt32) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE pending_actions SET payload = ?, epoch = ? WHERE action_id = ? AND delivery = 'queued'",
                arguments: [envelope, Int64(epoch), actionID])
            return db.changesCount == 1
        }
    }

    /// `sent` rows at or above `seq` become `queued` (keeping their `record_seq`); returns the first `queued` seq at
    /// or above it, nil when none.
    func requeue(fromSeq seq: UInt64) throws -> UInt64? {
        let from = Int64(clamping: seq)
        return try writer.write { db in
            try db.execute(
                sql: "UPDATE pending_actions SET delivery = 'queued' WHERE delivery = 'sent' AND action_seq >= ?",
                arguments: [from])
            let first = try Int64.fetchOne(
                db,
                sql: "SELECT MIN(action_seq) FROM pending_actions WHERE delivery = 'queued' AND action_seq >= ?",
                arguments: [from])
            return first.map { UInt64($0) }
        }
    }

    /// Rule 13 (relay client Phase 3): every ordered row not echoed yet (`queued` or `sent`) is `queued` again with
    /// no known version, so the next flush writes its same envelope with `.absent` on the transport the hub moved to.
    /// Returns how many rows it put back.
    func requeueForNewTransport() throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE pending_actions SET delivery = 'queued', record_seq = NULL
                WHERE action_seq IS NOT NULL AND delivery IN ('queued','sent')
                """)
            return db.changesCount
        }
    }

    /// Lists `queued` or `sent` rows under Not delivered: `state = failed`, `delivery = undelivered`, the local
    /// message and why (Ruling 16). A row already listed (or settled) is left as it is, so it keeps its first
    /// reason and message.
    func markUndelivered(actionIDs: [String], reason: UndeliveredReason, message: String) throws {
        guard !actionIDs.isEmpty else { return }
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE pending_actions
                    SET state = 'failed', delivery = 'undelivered', undelivered_reason = ?, error_message = ?
                    WHERE delivery IN ('queued','sent') AND action_id IN (\(Self.placeholders(actionIDs.count)))
                    """,
                arguments: StatementArguments([reason.rawValue, message] + actionIDs))
        }
    }

    /// The Not delivered list, by `action_seq`, opened like the overlay (a locked keychain throws).
    func undeliveredActions(from db: Database) throws -> [PendingAction] {
        try decodePendingActions(try Row.fetchAll(
            db,
            sql: "SELECT * FROM pending_actions WHERE delivery = 'undelivered' ORDER BY action_seq"
        ))
    }

    /// Waiting to send (`queued`) and Not delivered (`undelivered`) counts.
    public func outboxCounts(from db: Database) throws -> (queued: Int, undelivered: Int) {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(delivery = 'queued'), 0) AS queued,
                       COALESCE(SUM(delivery = 'undelivered'), 0) AS undelivered
                FROM pending_actions
                """)
        return (row?["queued"] ?? 0, row?["undelivered"] ?? 0)
    }

    /// The one delete of an overlay row (feature Dismiss, the list's Dismiss All, Retry's old row). Refuses a row
    /// that is `queued` or `sent` (still on its way); unknown ids are a no-op. Returns whether a row went.
    @discardableResult
    public func dismissAction(id: String) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM pending_actions
                    WHERE action_id = ? AND (delivery IS NULL OR delivery NOT IN ('queued','sent'))
                    """,
                arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Dismiss All: removes every Not delivered row; returns how many went.
    @discardableResult
    public func dismissAllUndelivered() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM pending_actions WHERE delivery = 'undelivered'")
            return db.changesCount
        }
    }

    // MARK: Controls

    /// Queues a sealed control behind those already queued; an id already queued is a no-op.
    func enqueueControl(_ control: QueuedControl) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO outbound_controls (control_id, kind, wire_name, envelope, queued_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    control.id, control.kind.rawValue, control.wireName, control.envelope, control.queuedAt.timeIntervalSince1970
                ])
        }
    }

    /// Whether an `epoch_ack` for `epoch` is due: above every epoch one was queued for.
    func epochAckDue(_ epoch: UInt32) throws -> Bool {
        try writer.read { db in try Self.ackedEpoch(db).map { epoch > $0 } ?? true }
    }

    /// Queues the sealed `epoch_ack` for `epoch` in place of any unsent one (always for a lower epoch) and records
    /// the epoch, in one transaction; false, nothing written, when `epoch` is not above the recorded one.
    func queueEpochAck(_ control: QueuedControl, epoch: UInt32) throws -> Bool {
        try writer.write { db in
            if let acked = try Self.ackedEpoch(db), epoch <= acked { return false }
            try db.execute(
                sql: "DELETE FROM outbound_controls WHERE kind = ?", arguments: [ControlKind.epochAck.rawValue])
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO outbound_controls (control_id, kind, wire_name, envelope, queued_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    control.id, control.kind.rawValue, control.wireName, control.envelope, control.queuedAt.timeIntervalSince1970
                ])
            try Self.setMeta(db, Self.epochAckKey, String(epoch))
            return true
        }
    }

    /// The queued controls in insertion order.
    func queuedControls() throws -> [QueuedControl] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM outbound_controls ORDER BY position").map { row in
                QueuedControl(
                    id: row["control_id"], kind: ControlKind(rawValue: row["kind"]), wireName: row["wire_name"], envelope: row["envelope"],
                    queuedAt: Date(timeIntervalSince1970: row["queued_at"]))
            }
        }
    }

    /// The control leaves the queue: written, or (hosted relay only) dropped past the mailbox TTL.
    func controlWritten(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM outbound_controls WHERE control_id = ?", arguments: [id])
        }
    }

    /// true the first time a hub control id is handled; ids older than 15 days are pruned (sim "Bounded state").
    func markControlHandled(id: String, at date: Date) throws -> Bool {
        try writer.write { db in
            try Self.pruneHandledControls(db, before: date.addingTimeInterval(-Self.handledControlRetention))
            try db.execute(
                sql: "INSERT OR IGNORE INTO handled_controls (control_id, handled_at) VALUES (?, ?)",
                arguments: [id, date.timeIntervalSince1970])
            return db.changesCount > 0
        }
    }

    /// Whether a hub control id was handled already. The feed reads this before handling a control and marks it
    /// after, so a throw in between leaves it unhandled and the replayed batch handles it again.
    func isControlHandled(id: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM handled_controls WHERE control_id = ?)", arguments: [id]) ?? false
        }
    }

    func pruneHandledControls(before date: Date) throws {
        try writer.write { db in try Self.pruneHandledControls(db, before: date) }
    }

    // MARK: Helpers

    private func fetchOutboxRows(where predicate: String, arguments: StatementArguments) throws -> [OutboxRow] {
        let rows = try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM pending_actions WHERE \(predicate) ORDER BY action_seq", arguments: arguments)
        }
        var readable: [OutboxRow] = []
        var badIDs: [String] = []
        for row in rows {
            if let outboxRow = Self.outboxRow(row) {
                readable.append(outboxRow)
            } else {
                badIDs.append(row["action_id"])
            }
        }
        let newBadIDs = badIDs
        let firstSeen = corruptPending.withLock { seen -> [String] in
            newBadIDs.filter { seen.insert($0).inserted }
        }
        for id in firstSeen {
            logger.warning("unreadable ordered pending_actions row skipped: \(id, privacy: .public)")
        }
        return readable
    }

    private static func pruneHandledControls(_ db: Database, before date: Date) throws {
        try db.execute(
            sql: "DELETE FROM handled_controls WHERE handled_at < ?", arguments: [date.timeIntervalSince1970])
    }

    private static func nextActionSeq(_ db: Database) throws -> UInt64 {
        guard let raw = try meta(db, actionSeqNextKey) else { return 1 }
        guard let seq = UInt64(raw), seq >= 1 else { throw ReplicaOutboxError.unreadableCounter(raw) }
        return seq
    }

    /// nil when no ack was queued yet, or the stored value does not read (the next ack then goes out).
    private static func ackedEpoch(_ db: Database) throws -> UInt32? {
        try meta(db, epochAckKey).flatMap { UInt32($0) }
    }

    private static func meta(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = ?", arguments: [key])
    }

    private static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO replica_meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value])
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// nil for a row whose ordered columns do not read (never written so by this module).
    private static func outboxRow(_ row: Row) -> OutboxRow? {
        guard let seq = row["action_seq"] as Int64?, let epoch = row["epoch"] as Int64?,
              let wireName = row["wire_name"] as String?,
              let delivery = (row["delivery"] as String?).flatMap(Delivery.init(rawValue:)),
              let envelope = row["payload"] as Data?
        else { return nil }
        return OutboxRow(
            actionID: row["action_id"], actionSeq: UInt64(seq), epoch: UInt32(truncatingIfNeeded: epoch),
            wireName: wireName, envelope: envelope, delivery: delivery,
            recordSeq: (row["record_seq"] as Int64?).map { UInt64($0) },
            sentAt: (row["sent_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}
