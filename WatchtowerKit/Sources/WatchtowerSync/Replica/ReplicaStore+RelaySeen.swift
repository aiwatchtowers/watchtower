import Foundation
import GRDB

/// Failures of the replica's own metadata.
public enum ReplicaStoreError: Error, Equatable {
    /// `envelope_seq_ceiling` holds something other than a u64: handing out seqs from 0 could reuse one.
    case unreadableSeqCeiling
}

/// The phone's relay rollback guard (F3), persisted in `relay_seen`, and the
/// phone's `SeqAllocator` store (F29). Both survive the format wipe.
extension ReplicaStore: RollbackGuard {
    static let relaySeenTableSQL = """
        CREATE TABLE IF NOT EXISTS relay_seen (
            wire_name TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            epoch INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            at REAL NOT NULL,
            PRIMARY KEY (wire_name, sender_id)
        )
        """

    private static let seqCeilingKey = "envelope_seq_ceiling"

    /// Versions compare as `(epoch, seq)`, epoch first; a u64 seq is stored by bit pattern.
    private static func stored(_ db: Database, wireName: String, senderID: UUID) throws -> (UInt32, UInt64)? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT epoch, seq FROM relay_seen WHERE wire_name = ? AND sender_id = ?",
            arguments: [wireName, senderID.uuidString]
        ) else { return nil }
        let epoch: Int64 = row["epoch"]
        let seq: Int64 = row["seq"]
        return (UInt32(truncatingIfNeeded: epoch), UInt64(bitPattern: seq))
    }

    public func check(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws -> RollbackVerdict {
        guard let stored = try writer.read({ db in try Self.stored(db, wireName: wireName, senderID: senderID) }) else {
            return .newer
        }
        let incoming = (epoch, seq)
        if incoming == stored { return .same }
        return incoming > stored ? .newer : .older
    }

    /// Keeps the highest version seen; `at` is when it was recorded (the prune clock).
    public func record(wireName: String, senderID: UUID, epoch: UInt32, seq: UInt64) throws {
        try writer.write { db in
            if let stored = try Self.stored(db, wireName: wireName, senderID: senderID), stored >= (epoch, seq) {
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO relay_seen (wire_name, sender_id, epoch, seq, at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(wire_name, sender_id) DO UPDATE SET
                        epoch = excluded.epoch, seq = excluded.seq, at = excluded.at
                    """,
                arguments: [
                    wireName, senderID.uuidString, Int64(epoch), Int64(bitPattern: seq), Date().timeIntervalSince1970
                ]
            )
        }
    }

    /// Drops guard rows recorded before `cutoff` (`ActionOutbox.sweepSilentPending` passes 8 days ago: past the
    /// 7-day action age window, so no record they guard can still be accepted).
    func pruneRelaySeen(before cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM relay_seen WHERE at < ?", arguments: [cutoff.timeIntervalSince1970])
        }
    }

    /// F29: the phone's `SeqAllocator` ceiling; 0 when never stored.
    public func envelopeSeqCeiling() throws -> UInt64 {
        let raw = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = ?", arguments: [Self.seqCeilingKey])
        }
        guard let raw else { return 0 }
        guard let value = UInt64(raw) else { throw ReplicaStoreError.unreadableSeqCeiling }
        return value
    }

    public func setEnvelopeSeqCeiling(_ value: UInt64) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO replica_meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [Self.seqCeilingKey, String(value)]
            )
        }
    }
}
