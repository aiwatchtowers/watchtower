import Foundation
import GRDB
import os

/// The mobile-side mirror of DataZone: one generic table of slice payloads
/// (`slice_records`) plus the persisted data-zone change token. The UI reads
/// it via `fetchAll` (typed decode) or ValueObservation on `reader`.
///
/// Mechanism: `init(path:)` opens a `DatabasePool` (WAL) so ValueObservation
/// can read concurrently with the hydrator's writes on-device; `inMemory()`
/// uses a `DatabaseQueue` because GRDB pools require a file. Both are
/// `DatabaseWriter`s and ValueObservation tracks both, so tests exercise the
/// same code paths.
public final class ReplicaStore: Sendable {
    private let writer: any DatabaseWriter
    private let corrupt = OSAllocatedUnfairLock(initialState: 0)
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
    public func apply(_ batch: CloudChangeBatch) throws {
        // JSONEncoder always emits valid UTF-8, so the nil branch is
        // unreachable; skipping only the token persistence would just
        // re-read the zone next cycle (safe — upserts are idempotent).
        let tokenJSON = String(bytes: try JSONEncoder().encode(batch.newToken), encoding: .utf8)
        try writer.write { db in
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
        }
    }

    public func storedToken() throws -> CloudChangeToken? {
        let raw = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = ?", arguments: [Self.dataTokenKey])
        }
        guard let raw else { return nil }
        guard let token = try? JSONDecoder().decode(CloudChangeToken.self, from: Data(raw.utf8)) else {
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
    /// `orderedBy` is a trusted compile-time ORDER BY fragment over
    /// slice_records columns (`record_name`, `modified_at`) — never user
    /// input. Typed sorting on model fields happens in memory after decode.
    /// Default: most recent first.
    public func fetchAll<T: FetchableRecord>(
        _ type: T.Type,
        kind: SliceKind,
        orderedBy sql: String? = nil
    ) throws -> [T] {
        let order = sql ?? "modified_at DESC, record_name"
        let payloads = try writer.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT payload FROM slice_records WHERE kind = ? ORDER BY \(order)",
                arguments: [kind.rawValue]
            )
        }
        var decoded: [T] = []
        var skipped = 0
        for payload in payloads {
            do {
                decoded.append(try T(row: RowPayloadCoder.row(from: payload)))
            } catch {
                skipped += 1
            }
        }
        if skipped > 0 {
            let count = skipped // immutable copy for the @Sendable withLock closure
            corrupt.withLock { $0 += count }
            logger.warning("skipped \(count, privacy: .public) undecodable \(kind.rawValue, privacy: .public) payloads")
        }
        return decoded
    }

    /// Cumulative count of payloads skipped by `fetchAll` since init.
    public func corruptCount() -> Int {
        corrupt.withLock { $0 }
    }
}
