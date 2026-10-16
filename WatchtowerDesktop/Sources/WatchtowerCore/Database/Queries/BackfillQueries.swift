import Foundation
import GRDB

/// One daemon-written `history_backfill` row, as the progress line needs it.
package struct BackfillRow: Equatable {
    package let status: String      // running | paused | done | off
    package let waiting: String     // "" | plan_limit
    package let floorTS: Double
    package let upperTS: Double
    package let reachedTS: Double
}

/// Reads of the daemon-written `history_backfill` (first-run month backfill).
package enum BackfillQueries {
    package static func rows(_ db: Database) throws -> [BackfillRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT status, waiting, floor_ts, upper_ts, reached_ts FROM history_backfill ORDER BY id
            """)
        return rows.map { row in
            BackfillRow(status: row["status"], waiting: row["waiting"], floorTS: row["floor_ts"],
                        upperTS: row["upper_ts"], reachedTS: row["reached_ts"])
        }
    }
}
