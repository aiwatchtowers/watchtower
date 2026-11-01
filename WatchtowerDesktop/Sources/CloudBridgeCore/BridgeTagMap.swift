import Foundation
import GRDB

/// The bridge's own state, `<hub dir>/cloudkit/bridge.db` (dir 0700, file 0600): ids and numbers only. CloudKit
/// change tags never cross the socket; this map numbers them instead.
///
/// - Every record's change tag gets a `tag_seq` (u64): the same tag keeps its number, a new tag a new one.
///   The record's archived system fields (its id, change tag and server dates — never a payload field) ride
///   along, so a conditional save can send the tag back to CloudKit.
/// - Every zone's change feed is numbered by cursors: a cursor names the CloudKit server change token to fetch
///   from. Only the newest `keptCursors` per zone are kept; an older one reads as expired.
/// - A `generation`, minted when the file is created and persisted with it, owns every number: the Go side
///   never compares numbers of two generations, and the bridge refuses a cursor or tag of another one.
///
/// Numbers come from one counter, so a tag_seq is never reused and never passes for a cursor of the same
/// value by meaning — the Go side compares neither.
public final class BridgeTagMap: @unchecked Sendable {
    /// One record's last known state.
    public struct Entry: Equatable, Sendable {
        public let changeTag: String
        public let tagSeq: UInt64
        public let systemFields: Data
    }

    public enum MapError: Error, Equatable {
        /// A cursor this map does not keep (never issued, pruned, or of another generation).
        case unknownCursor
    }

    /// How many cursors a zone keeps.
    public static let keptCursors = 32

    public let generation: String
    private let queue: DatabaseQueue

    /// Opens (or creates) `bridge.db` in `directory`, which is created 0700 when missing.
    public init(directory: URL, mintGeneration: () -> String = BridgeTagMap.randomGeneration) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("bridge.db").path
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE record_tags (
                    zone TEXT NOT NULL, name TEXT NOT NULL, change_tag TEXT NOT NULL,
                    tag_seq INTEGER NOT NULL, system_fields BLOB NOT NULL,
                    PRIMARY KEY (zone, name));
                CREATE TABLE cursors (
                    zone TEXT NOT NULL, seq INTEGER NOT NULL, token BLOB,
                    PRIMARY KEY (zone, seq));
                """)
        }
        try migrator.migrate(queue)
        generation = try queue.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'generation'") {
                return existing
            }
            let minted = mintGeneration()
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('generation', ?), ('next_seq', '1')", arguments: [minted])
            return minted
        }
    }

    /// 16 lower-case hex characters from the system's random source.
    public static func randomGeneration() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    private static func nextSeq(_ db: Database) throws -> UInt64 {
        let raw = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'next_seq'") ?? "1"
        let seq = UInt64(raw) ?? 1
        try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'next_seq'", arguments: [String(seq + 1)])
        return seq
    }

    /// The record's last known state; nil when the map has none.
    public func entry(zone: String, name: String) throws -> Entry? {
        try queue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT change_tag, tag_seq, system_fields FROM record_tags WHERE zone = ? AND name = ?",
                arguments: [zone, name])
            return row.map { Entry(changeTag: $0[0], tagSeq: UInt64(bitPattern: $0[1] as Int64), systemFields: $0[2]) }
        }
    }

    /// The record's tag_seq for `changeTag`: its number when the map holds that tag, else a new one, stored.
    public func record(zone: String, name: String, changeTag: String, systemFields: Data) throws -> UInt64 {
        try queue.write { db in
            if let row = try Row.fetchOne(
                db, sql: "SELECT change_tag, tag_seq FROM record_tags WHERE zone = ? AND name = ?", arguments: [zone, name]),
               row[0] as String == changeTag {
                try db.execute(
                    sql: "UPDATE record_tags SET system_fields = ? WHERE zone = ? AND name = ?",
                    arguments: [systemFields, zone, name])
                return UInt64(bitPattern: row[1] as Int64)
            }
            let seq = try Self.nextSeq(db)
            try db.execute(
                sql: """
                    INSERT INTO record_tags (zone, name, change_tag, tag_seq, system_fields) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (zone, name) DO UPDATE SET
                        change_tag = excluded.change_tag, tag_seq = excluded.tag_seq, system_fields = excluded.system_fields
                    """,
                arguments: [zone, name, changeTag, Int64(bitPattern: seq), systemFields])
            return seq
        }
    }

    /// The record is gone.
    public func forget(zone: String, name: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM record_tags WHERE zone = ? AND name = ?", arguments: [zone, name])
        }
    }

    /// The server change token `cursor` names: nil for 0 (from the start) and for a cursor stored without one.
    /// Throws `unknownCursor` for a cursor the map does not keep.
    public func token(zone: String, cursor: UInt64) throws -> Data? {
        guard cursor != 0 else { return nil }
        return try queue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT token FROM cursors WHERE zone = ? AND seq = ?", arguments: [zone, Int64(bitPattern: cursor)])
            else { throw MapError.unknownCursor }
            return row[0] as Data?
        }
    }

    /// A cursor for `token` in `zone`: the newest one when it names the same token (unless `fresh`), else a new
    /// one (the zone's oldest cursors past `keptCursors` are dropped).
    public func cursor(zone: String, token: Data?, fresh: Bool = false) throws -> UInt64 {
        try queue.write { db in
            if !fresh, let row = try Row.fetchOne(
                db, sql: "SELECT seq, token FROM cursors WHERE zone = ? ORDER BY seq DESC LIMIT 1", arguments: [zone]),
               row[1] as Data? == token {
                return UInt64(bitPattern: row[0] as Int64)
            }
            let seq = try Self.nextSeq(db)
            try db.execute(
                sql: "INSERT INTO cursors (zone, seq, token) VALUES (?, ?, ?)",
                arguments: [zone, Int64(bitPattern: seq), token])
            try db.execute(
                sql: """
                    DELETE FROM cursors WHERE zone = ? AND seq NOT IN (
                        SELECT seq FROM cursors WHERE zone = ? ORDER BY seq DESC LIMIT ?)
                    """,
                arguments: [zone, zone, Self.keptCursors])
            return seq
        }
    }
}
