import Foundation
import GRDB

/// One daemon-written `history_backfill` row, as the progress line needs it.
package struct BackfillRow: Equatable {
    package let status: String      // running | paused | done | off
    package let waiting: String     // "" | plan_limit | held (held_since set, #580)
    package let floorTS: Double
    package let upperTS: Double
    package let reachedTS: Double
}

/// Reads of the daemon-written `history_backfill` (first-run month backfill).
package enum BackfillQueries {
    /// `waiting` reads "held" while transient failures hold the row (held_since
    /// set and no plan-limit wait), as `watchtower backfill status` does. A
    /// database from before migration 00130 (a new app on an old daemon) has
    /// no held_since and never reads "held".
    package static func rows(_ db: Database) throws -> [BackfillRow] {
        let waiting = try hasHeldSince(db)
            ? "CASE WHEN waiting = '' AND held_since IS NOT NULL THEN 'held' ELSE waiting END"
            : "waiting"
        let rows = try Row.fetchAll(db, sql: """
            SELECT status, \(waiting) AS waiting, floor_ts, upper_ts, reached_ts
            FROM history_backfill ORDER BY id
            """)
        return rows.map { row in
            BackfillRow(status: row["status"], waiting: row["waiting"], floorTS: row["floor_ts"],
                        upperTS: row["upper_ts"], reachedTS: row["reached_ts"])
        }
    }

    /// Whether the database has migration 00130's held_since column (GRDB
    /// caches the probe per connection).
    private static func hasHeldSince(_ db: Database) throws -> Bool {
        try db.columns(in: "history_backfill").contains { $0.name == "held_since" }
    }
}
