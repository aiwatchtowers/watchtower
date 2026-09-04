import Foundation
import GRDB

/// DB access for Catch-Up absence recaps. Reads mirror the Go store
/// (`internal/db/catchup_store.go`); `acknowledge` is the Swift half of the
/// CATCHUP-01 dual path — the Desktop "I'm caught up" button writes the shared
/// DB directly and never calls the CLI, so its SQL must stay the exact twin of
/// Go's `AcknowledgeCatchupWindow`.
package enum CatchUpQueries {

    // MARK: - Fetch

    /// Newest recaps first (the Go `ListCatchupRecaps` order).
    package static func fetchRecaps(_ db: Database, limit: Int = 50) throws -> [CatchUpRecap] {
        try CatchUpRecap.fetchAll(
            db,
            sql: "SELECT * FROM catchup_recaps ORDER BY id DESC LIMIT ?",
            arguments: [limit]
        )
    }

    package static func fetchRecap(_ db: Database, id: Int) throws -> CatchUpRecap? {
        try CatchUpRecap.fetchOne(db, sql: "SELECT * FROM catchup_recaps WHERE id = ?", arguments: [id])
    }

    /// Reactive observation of the recap list — a CLI run inserting or finishing
    /// a row pushes straight into the Desktop list.
    package static func observeRecaps(limit: Int = 50) -> ValueObservation<ValueReducers.Fetch<[CatchUpRecap]>> {
        ValueObservation.tracking { db in try fetchRecaps(db, limit: limit) }
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

    // MARK: - Acknowledge (window-scoped mark-read)

    /// Why an acknowledge was refused. The Go twin (`Pipeline.Acknowledge`)
    /// returns the same refusal as an error.
    package enum AcknowledgeError: Swift.Error, LocalizedError {
        /// The recap never finished composing, or failed. Marking its window
        /// read would clear everything in it without the operator ever having
        /// been shown what was there.
        case notReady(status: String)

        package var errorDescription: String? {
            switch self {
            case let .notReady(status):
                "This recap is \(status), not ready to acknowledge."
            }
        }
    }

    /// Marks everything inside the recap's window read on the five `read_at`
    /// surfaces and stamps the recap's own `acknowledged_at` (first stamp wins).
    ///
    /// BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md. The exact twin of Go's
    /// `AcknowledgeCatchupWindow`: the same six set-based statements in the same
    /// order, the same edges, each predicate already excluding the rows it marked
    /// so a second ack is a no-op. Selection is by **window**, never by the refs
    /// the compose call happened to cite — so this must not be rebuilt on the
    /// per-id `MarkXRead` helpers.
    ///
    /// The two summary surfaces (`digests`, `stream_digests`) use the OVERLAP
    /// predicate `period_to > from AND period_from < to`, matching the Go gather
    /// (`ListCatchupDigests`/`ListCatchupStreams`) exactly: a digest produced by
    /// the run's own coverage top-up stamps its `period_to` with its own
    /// `time.Now()`, landing a second or two past `to`, and a `period_to <= to`
    /// ack would leave such a cited digest unread forever. `tracks` and
    /// `inbox_items` compare a single instant, so they keep `(from, to]`;
    /// `briefings` compares LOCAL calendar dates inclusively.
    ///
    /// Runs inside the caller's `write` block, which supplies the transaction the
    /// Go path opens explicitly. Throws `AcknowledgeError.notReady` for a recap
    /// that is not `ready`, exactly as the Go path refuses one.
    package static func acknowledge(_ db: Database, recap: CatchUpRecap) throws {
        guard recap.isReady else { throw AcknowledgeError.notReady(status: recap.status) }
        let from = recap.periodFrom
        let to = recap.periodTo
        let fromISO = Self.isoString(from)
        let toISO = Self.isoString(to)
        let fromDate = Self.localDateString(from)
        // `to` is an EXCLUSIVE instant, so the last local DAY the window covers is
        // the one containing to−1s: a window ending exactly on a local midnight
        // (the `yesterday` preset) covers the previous day, and the briefing dated
        // the new day must stay unread. The Go twin derives it the same way.
        let toDate = Self.localDateString(to - 1)

        try db.execute(
            sql: """
                UPDATE digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE read_at IS NULL AND type = 'channel' AND period_to > ? AND period_from < ?
                """,
            arguments: [from, to]
        )
        try db.execute(
            sql: """
                UPDATE stream_digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE read_at IS NULL AND period_to > ? AND period_from < ?
                """,
            arguments: [fromISO, toISO]
        )
        try db.execute(
            sql: """
                UPDATE tracks SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), has_updates = 0
                WHERE dismissed_at = '' AND updated_at > ? AND updated_at <= ?
                  AND (read_at IS NULL OR has_updates = 1)
                """,
            arguments: [fromISO, toISO]
        )
        try db.execute(
            sql: """
                UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE read_at IS NULL AND created_at > ? AND created_at <= ?
                """,
            arguments: [fromISO, toISO]
        )
        try db.execute(
            sql: """
                UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE read_at IS NULL AND date >= ? AND date <= ?
                """,
            arguments: [fromDate, toDate]
        )
        try db.execute(
            sql: """
                UPDATE catchup_recaps
                SET acknowledged_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = ? AND acknowledged_at IS NULL
                """,
            arguments: [recap.id]
        )
    }

    // MARK: - Window-bound formatting

    /// UTC `yyyy-MM-ddTHH:mm:ssZ` — the form Go writes into the ISO timestamp
    /// columns (`time.Unix(...).UTC().Format("2006-01-02T15:04:05Z")`).
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static func isoString(_ unix: Double) -> String {
        // Go truncates to whole seconds via int64(); match it, so a fractional
        // window bound can never round the boundary a second the wrong way.
        Self.isoFormatter.string(from: Date(timeIntervalSince1970: unix.rounded(.towardZero)))
    }

    /// `yyyy-MM-dd` in the CURRENT time zone: `briefings.date` is a local calendar
    /// date and Go formats the window bounds with `.Local()`. Built per call so a
    /// time-zone change mid-session cannot leave a stale zone cached.
    private static func localDateString(_ unix: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: unix.rounded(.towardZero)))
    }
}
