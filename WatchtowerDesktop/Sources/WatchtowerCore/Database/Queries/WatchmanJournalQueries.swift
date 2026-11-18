import Foundation
import GRDB

/// The morning journal's reads over `watchman_items` and `watchman_gaps`
/// (spec §10). Pure reads: the Desktop writes only the feedback columns,
/// in `WatchmanFeedbackQueries`.
package enum WatchmanJournalQueries {
    /// The tables a journal observation tracks.
    package static let observedTables = ["watchman_items", "watchman_gaps"]

    private static let itemColumns = """
        i.id, i.workbench_id, p.name AS workbench_name, i.session_id, i.target_id, i.kind, i.state, i.outcome,
        i.question, i.choice, i.rationale, i.precedent_ids, i.confidence, i.category, i.unsure, i.park_reason,
        i.delivery, i.cost_usd, i.created_at, i.decided_at, i.feedback, i.feedback_text, i.check_done_at
        """

    /// The newest `limit` nights that have an item, newest first. A night
    /// runs from 12:00 local to 12:00 the next day; an item belongs to the
    /// night it was created in, and a sleep gap to every night it overlaps.
    /// `since`/`before` keep only items created in that range.
    package static func nights(
        _ db: Database, limit: Int, since: Date? = nil, before: Date? = nil, calendar: Calendar = .current
    ) throws -> [WatchmanNight] {
        guard limit > 0 else { return [] }
        let from = since.map(AutomationDates.format) ?? "0000-01-01T00:00:00Z"
        let until = before.map(AutomationDates.format) ?? "9999-12-31T23:59:59Z"
        // One newest-item lookup per night, each below the last night's
        // start: at most `limit` rows ever reach Swift.
        var starts: [Date] = []
        var below = until
        while starts.count < limit {
            let stamp = try String.fetchOne(db, sql: """
                SELECT created_at FROM watchman_items WHERE created_at < ? AND created_at >= ?
                ORDER BY created_at DESC LIMIT 1
                """, arguments: [below, from])
            guard let stamp else { break }
            guard let created = AutomationDates.parse(stamp) else {
                throw WatchmanItemError.badTime(column: "created_at", value: stamp)
            }
            let start = WatchmanNight.start(of: created, calendar: calendar)
            starts.append(start)
            below = AutomationDates.format(start)
        }
        guard let oldest = starts.last else { return [] }
        let items = try WatchmanItem.fetchAll(db, sql: """
            SELECT \(itemColumns)
            FROM watchman_items i LEFT JOIN projects p ON p.id = i.workbench_id
            WHERE i.created_at >= ? AND i.created_at < ?
            ORDER BY i.created_at, i.id
            """, arguments: [AutomationDates.format(max(oldest, since ?? oldest)), until])
        let gaps = try self.gaps(db, endingAfter: oldest)
        return starts.map { start in
            night(start, items: items.filter { WatchmanNight.start(of: $0.createdAt, calendar: calendar) == start },
                  gaps: gaps, calendar: calendar)
        }
    }

    /// Items the twin is deciding right now, oldest first (the busy line).
    package static func liveDeciding(_ db: Database) throws -> [WatchmanItem] {
        try WatchmanItem.fetchAll(db, sql: """
            SELECT \(itemColumns)
            FROM watchman_items i LEFT JOIN projects p ON p.id = i.workbench_id
            WHERE i.state = 'deciding'
            ORDER BY i.created_at, i.id
            """)
    }

    /// The first line of each precedent's situation, by id: what a
    /// decision leaned on. An id whose precedent is gone is left out.
    package static func precedentTitles(_ db: Database, ids: Set<Int64>) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, situation FROM watchman_precedents WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(Array(ids)))
        var titles: [Int64: String] = [:]
        for row in rows {
            let situation: String = row["situation"]
            let line = situation.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if !line.isEmpty { titles[row["id"]] = line }
        }
        return titles
    }

    /// The Inbox entry's summary; nil while Watchman was never turned on
    /// and has no item (or on a database without its tables).
    package static func inboxSummary(_ db: Database, calendar: Calendar = .current) throws -> WatchmanInboxSummary? {
        guard try db.tableExists("watchman_items"), try db.tableExists("watchman_workbenches") else { return nil }
        let latest = try nights(db, limit: 1, calendar: calendar).first
        let enabledAt = try String.fetchOne(db, sql: "SELECT MAX(enabled_at) FROM watchman_workbenches")
        guard let updatedAt = latest?.items.last?.createdAt ?? AutomationDates.parse(enabledAt) else { return nil }
        let waiting = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM watchman_items
            WHERE state = 'done' AND outcome IN ('parked', 'handed') AND feedback = ''
            """) ?? 0
        return WatchmanInboxSummary(latest: latest.map(WatchmanNightCounts.init), waiting: waiting, updatedAt: updatedAt)
    }

    /// Home's row: the newer of tonight and last night that decided or
    /// parked anything; nil when neither did.
    package static func homeNight(_ db: Database, now: Date, calendar: Calendar = .current) throws -> WatchmanNightCounts? {
        guard try db.tableExists("watchman_items") else { return nil }
        let tonight = WatchmanNight.start(of: now, calendar: calendar)
        let lastNight = WatchmanNight.start(of: tonight.addingTimeInterval(-1), calendar: calendar)
        // Only [last night, tonight]: an item stamped after tonight (a clock
        // that went back) never shows as Home's night.
        return try nights(db, limit: 2, since: lastNight, before: WatchmanNight.end(of: tonight, calendar: calendar),
                          calendar: calendar)
            .map(WatchmanNightCounts.init)
            .first { $0.decided + $0.waiting > 0 }
    }

    // MARK: - Private

    private static func gaps(_ db: Database, endingAfter start: Date) throws -> [ClosedRange<Date>] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT started_at, ended_at FROM watchman_gaps WHERE ended_at >= ? ORDER BY started_at
            """, arguments: [AutomationDates.format(start)])
        return try rows.map { row in
            let started: String = row["started_at"]
            let ended: String = row["ended_at"]
            guard let from = AutomationDates.parse(started) else {
                throw WatchmanItemError.badTime(column: "started_at", value: started)
            }
            guard let to = AutomationDates.parse(ended) else {
                throw WatchmanItemError.badTime(column: "ended_at", value: ended)
            }
            return from...max(from, to)
        }
    }

    private static func night(
        _ start: Date, items: [WatchmanItem], gaps: [ClosedRange<Date>], calendar: Calendar
    ) -> WatchmanNight {
        let end = WatchmanNight.end(of: start, calendar: calendar)
        var night = WatchmanNight(date: start)
        for item in items {
            if item.state != "done" {
                night.pending.append(item)
            } else if item.waitsForOwner {
                night.waiting.append(item)
            } else if item.outcome == "owner_first" {
                night.ownerFirst.append(item)
            } else if item.kind == "check" {
                if item.isCheckNobodyRan { night.checks.append(item) }
            } else {
                night.decided.append(item)
            }
        }
        night.gaps = gaps.filter { $0.lowerBound < end && $0.upperBound > start }
        night.costUSD = items.reduce(0) { $0 + $1.costUSD }
        return night
    }
}
