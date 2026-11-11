import Foundation
import GRDB

/// One finished action timing: when it ended, on which transport, how long the Mac took to answer and to show the
/// result. No ids, kinds or text.
public struct LatencySample: Equatable, Sendable {
    public let at: Date
    public let transport: TransportKind
    public let answerMs: Int
    public let resultMs: Int

    public init(at: Date, transport: TransportKind, answerMs: Int, resultMs: Int) {
        self.at = at
        self.transport = transport
        self.answerMs = answerMs
        self.resultMs = resultMs
    }
}

/// The phone's action timings (relay client Phase 4). `latency_pending` holds an open action's id, kind and three
/// stamps and is deleted when it settles or expires; `latency_samples` holds the content-free results. Nothing
/// leaves the phone. One writer per replica; every call is a short transaction of its own, never joined to the
/// outbox's. A row settled twice is a no-op (the delete and the insert share one transaction).
extension ReplicaStore {
    static let latencyTablesSQL = """
        CREATE TABLE IF NOT EXISTS latency_pending (
            action_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            transport TEXT NOT NULL,
            written_at REAL NOT NULL,
            answered_at REAL,
            effect_at REAL
        );
        CREATE TABLE IF NOT EXISTS latency_samples (
            at REAL NOT NULL,
            transport TEXT NOT NULL,
            answer_ms INTEGER NOT NULL,
            result_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_latency_samples_at ON latency_samples(at)
        """

    /// An open row older than this is dropped: the hub's `SaveWait`.
    public static let latencyResultWait: TimeInterval = 60
    public static let latencyWindow: TimeInterval = 604_800
    public static let latencyMaxRows = 5_000

    /// The save that landed for `actionID` started at `at`. Only a kind with effect kinds opens a row.
    func latencyWritten(actionID: String, kind: String, transport: TransportKind, at: Date) throws {
        guard !ActionEffectKinds.kinds(for: kind).isEmpty else { return }
        try writer.write { db in
            try Self.expire(db, now: at)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO latency_pending (action_id, kind, transport, written_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [actionID, kind, transport.rawValue, at.timeIntervalSince1970])
        }
    }

    /// The action's final echo: `applied` stamps (the first stamp wins), anything else drops the row.
    func latencyAnswered(actionID: String, applied: Bool, at: Date) throws {
        try writer.write { db in
            try Self.expire(db, now: at)
            guard applied else {
                try db.execute(sql: "DELETE FROM latency_pending WHERE action_id = ?", arguments: [actionID])
                return
            }
            try db.execute(
                sql: "UPDATE latency_pending SET answered_at = COALESCE(answered_at, ?) WHERE action_id = ?",
                arguments: [at.timeIntervalSince1970, actionID])
            try Self.settle(db, now: at)
        }
    }

    /// A slice of `kind` was stored: every open row whose action kind maps to it takes its first effect stamp.
    func latencyEffect(kind: String, at: Date) throws {
        try writer.write { db in
            try Self.expire(db, now: at)
            let rows = try Row.fetchAll(db, sql: "SELECT action_id, kind FROM latency_pending WHERE effect_at IS NULL")
            for row in rows {
                let actionKind: String = row["kind"]
                guard ActionEffectKinds.kinds(for: actionKind).contains(kind) else { continue }
                try db.execute(
                    sql: "UPDATE latency_pending SET effect_at = ? WHERE action_id = ?",
                    arguments: [at.timeIntervalSince1970, row["action_id"] as String])
            }
            try Self.settle(db, now: at)
        }
    }

    /// Stamps the effect of each kind among `indexed` at `at`, the moment the slices became visible: the hydrator's
    /// pass and the session's late index (a key arrived) both end here, so a timing never counts a slice that sat
    /// unopened as seen. A failure logs its error type only and never fails the caller.
    public func stampLatencyEffects(of indexed: [AppliedSliceRecord], at: Date) {
        guard !indexed.isEmpty else { return }
        do {
            for kind in Set(indexed.map(\.kind.rawValue)) { try latencyEffect(kind: kind, at: at) }
        } catch {
            logger.error("latency stamp failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func latencyDrop(actionID: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM latency_pending WHERE action_id = ?", arguments: [actionID])
        }
    }

    /// Drops the open rows older than `latencyResultWait`, the samples past the window and the oldest beyond
    /// `latencyMaxRows`.
    func latencySweep(now: Date) throws {
        try writer.write { db in
            try Self.expire(db, now: now)
            try Self.prune(db, now: now)
        }
    }

    /// The samples that ended at or after `since`, oldest first.
    public func latencySamples(since: Date) throws -> [LatencySample] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT at, transport, answer_ms, result_ms FROM latency_samples WHERE at >= ? ORDER BY at, rowid",
                arguments: [since.timeIntervalSince1970])
            return rows.compactMap { row in
                guard let transport = TransportKind(rawValue: row["transport"]) else { return nil }
                return LatencySample(
                    at: Date(timeIntervalSince1970: row["at"]), transport: transport,
                    answerMs: row["answer_ms"], resultMs: row["result_ms"])
            }
        }
    }

    /// The kind of an open ordered or legacy action (the outbox row carries none).
    func actionKindForLatency(id: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT kind FROM pending_actions WHERE action_id = ?", arguments: [id])
        }
    }

    // MARK: - In one transaction

    private static func expire(_ db: Database, now: Date) throws {
        try db.execute(
            sql: "DELETE FROM latency_pending WHERE written_at < ?",
            arguments: [now.timeIntervalSince1970 - latencyResultWait])
    }

    private static func prune(_ db: Database, now: Date) throws {
        try db.execute(
            sql: "DELETE FROM latency_samples WHERE at < ?", arguments: [now.timeIntervalSince1970 - latencyWindow])
        try db.execute(
            sql: """
                DELETE FROM latency_samples WHERE rowid IN
                    (SELECT rowid FROM latency_samples ORDER BY at DESC, rowid DESC LIMIT -1 OFFSET ?)
                """,
            arguments: [latencyMaxRows])
    }

    /// Every row with both stamps becomes a sample (or is dropped when a clock moved) and is deleted, together.
    private static func settle(_ db: Database, now: Date) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT action_id, transport, written_at, answered_at, effect_at FROM latency_pending
                WHERE answered_at IS NOT NULL AND effect_at IS NOT NULL
                """)
        guard !rows.isEmpty else { return }
        for row in rows {
            let id: String = row["action_id"]
            let written: Double = row["written_at"]
            let answered: Double = row["answered_at"]
            let effect: Double = row["effect_at"]
            let answerMs = Int(((answered - written) * 1000).rounded())
            let resultMs = Int(((max(answered, effect) - written) * 1000).rounded())
            // The delete decides: a row settled by another end is gone and records nothing.
            try db.execute(sql: "DELETE FROM latency_pending WHERE action_id = ?", arguments: [id])
            guard db.changesCount == 1, answerMs >= 0, resultMs >= 0 else { continue }
            try db.execute(
                sql: "INSERT INTO latency_samples (at, transport, answer_ms, result_ms) VALUES (?, ?, ?, ?)",
                arguments: [max(answered, effect), row["transport"] as String, answerMs, resultMs])
        }
        try prune(db, now: now)
    }
}
