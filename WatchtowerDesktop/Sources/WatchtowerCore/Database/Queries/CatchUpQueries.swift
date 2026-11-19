import Foundation
import GRDB

/// DB access for Catch-Up absence recaps. Reads mirror the Go store
/// (`internal/db/catchup_store.go`); `acknowledge` is the Swift half of the
/// CATCHUP-01 dual path — the Desktop "I'm caught up" button writes the shared
/// DB directly and never calls the CLI, so its SQL must stay the exact twin of
/// Go's `AcknowledgeCatchupWindow`.
package enum CatchUpQueries {

    // MARK: - Fetch

    /// Newest recaps first (the Go `ListCatchupRecaps` order). `now` decides
    /// which `building` rows read as stale (`CatchUpRecap.init(row:now:)`).
    package static func fetchRecaps(_ db: Database, limit: Int = 50, now: Date = Date()) throws -> [CatchUpRecap] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM catchup_recaps ORDER BY id DESC LIMIT ?",
            arguments: [limit]
        )
        return rows.map { CatchUpRecap(row: $0, now: now) }
    }

    package static func fetchRecap(_ db: Database, id: Int) throws -> CatchUpRecap? {
        try CatchUpRecap.fetchOne(db, sql: "SELECT * FROM catchup_recaps WHERE id = ?", arguments: [id])
    }

    /// Reactive observation of the recap list — a CLI run inserting or finishing
    /// a row pushes straight into the Desktop list.
    package static func observeRecaps(
        limit: Int = 50, now: @escaping @Sendable () -> Date = { Date() }
    ) -> ValueObservation<ValueReducers.Fetch<[CatchUpRecap]>> {
        ValueObservation.tracking { db in try fetchRecaps(db, limit: limit, now: now()) }
    }

    /// Start of the next **auto** window: `period_to` of the most recently
    /// acknowledged recap, or nil when nothing has been acknowledged yet (the
    /// caller then falls back to `now − 24h`, as `catchup run` does). Mirrors Go
    /// `LastAcknowledgedCatchupTo`, which reports the same "none" case as 0.
    package static func autoWindowStart(_ db: Database) throws -> Date? {
        let to = try Double.fetchOne(
            db,
            sql: "SELECT MAX(period_to) FROM catchup_recaps WHERE acknowledged_at IS NOT NULL"
        )
        guard let to else { return nil }
        return Date(timeIntervalSince1970: to)
    }

    /// Whether a finished recap is still waiting for "I'm caught up" — the
    /// sidebar badge condition.
    package static func hasUnacknowledgedReady(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM catchup_recaps WHERE status = 'ready' AND acknowledged_at IS NULL)"
        ) ?? false
    }

    /// The newest recap `hasUnacknowledgedReady` counts — Home's "Since you
    /// were away" card. Newest by id, as `fetchRecaps`.
    package static func newestUnacknowledgedReady(_ db: Database) throws -> CatchUpRecap? {
        try CatchUpRecap.fetchOne(
            db,
            sql: "SELECT * FROM catchup_recaps WHERE status = 'ready' AND acknowledged_at IS NULL ORDER BY id DESC LIMIT 1"
        )
    }
}
