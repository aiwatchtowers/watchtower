import Foundation
import GRDB

/// Per-kind change stamps (board #724): `slice_kind_versions` holds one
/// counter per slice kind, bumped in the same transaction as every
/// `apply` that upserts or deletes a record of that kind. A screen's
/// observation tracks this small table (plus its own sidecar tables), not
/// `slice_records`, and re-decodes a kind only when its stamp moved, so a
/// heartbeat write never re-decodes the board or the calendar.
///
/// Replica schema: created with `CREATE TABLE IF NOT EXISTS` like the rest
/// of the replica (it is not the Go goose database). A replica from before
/// it has no rows: every kind reads as version 0 until its next write.
extension ReplicaStore {
    static let kindVersionsTableSQL = """
        CREATE TABLE IF NOT EXISTS slice_kind_versions (
            kind TEXT PRIMARY KEY,
            version INTEGER NOT NULL
        )
        """

    /// The change stamps' table: what a per-kind observation tracks.
    public static var kindVersionsRegion: any DatabaseRegionConvertible { Table("slice_kind_versions") }
    /// The outbox overlay (`pending_actions`).
    public static var pendingActionsRegion: any DatabaseRegionConvertible { Table("pending_actions") }
    /// The phone's recordings ledger and its marks.
    public static var phoneRecordingsRegions: [any DatabaseRegionConvertible] {
        [Table("phone_recordings"), Table("phone_recording_marks")]
    }

    /// The change stamp of each kind in `kinds`, from an ALREADY-OPEN
    /// database (the same snapshot the payloads are read in); a kind never
    /// written reads 0. A stamp only grows while this replica file lives.
    public func kindVersions(_ kinds: [SliceKind], from db: Database) throws -> [SliceKind: Int64] {
        var versions = Dictionary(uniqueKeysWithValues: kinds.map { ($0, Int64(0)) })
        guard !kinds.isEmpty else { return versions }
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT kind, version FROM slice_kind_versions WHERE kind IN (\(placeholders))",
            arguments: StatementArguments(kinds.map(\.rawValue))
        )
        for row in rows {
            if let kind = SliceKind(rawValue: row["kind"]) {
                versions[kind] = row["version"]
            }
        }
        return versions
    }

    static func bumpKindVersions(_ kinds: Set<String>, in db: Database) throws {
        for kind in kinds {
            try db.execute(
                sql: """
                    INSERT INTO slice_kind_versions (kind, version) VALUES (?, 1)
                    ON CONFLICT(kind) DO UPDATE SET version = version + 1
                    """,
                arguments: [kind]
            )
        }
    }
}
