import Foundation
import GRDB

package enum BriefingQueries {
    package static func fetchRecent(
        _ db: Database,
        limit: Int = 30,
        offset: Int = 0
    ) throws -> [Briefing] {
        try Briefing.fetchAll(
            db,
            sql: """
                SELECT * FROM briefings
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?
                """,
            arguments: [limit, offset]
        )
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> Briefing? {
        try Briefing.fetchOne(
            db,
            sql: "SELECT * FROM briefings WHERE id = ?",
            arguments: [id]
        )
    }

    /// Fetch the most recent briefing for a specific date (YYYY-MM-DD).
    package static func fetchByDate(_ db: Database, date: String) throws -> Briefing? {
        try Briefing.fetchOne(
            db,
            sql: "SELECT * FROM briefings WHERE date = ? ORDER BY created_at DESC LIMIT 1",
            arguments: [date]
        )
    }

    /// One card per date over the briefings and the day plans, newest date
    /// first. Each date takes its briefing and its plan (either may be nil) and
    /// the plan's done/total item counts. Four reads whatever the page size
    /// (the dates, their briefings, their plans, the plans' item counts):
    /// the Inbox reads this on every 30 s tick.
    package static func fetchDayCards(_ db: Database, limit: Int, offset: Int = 0) throws -> [InboxDayCard] {
        let dates = try String.fetchAll(db, sql: """
            SELECT date FROM (
                SELECT date AS date FROM briefings UNION SELECT plan_date AS date FROM day_plans
            ) ORDER BY date DESC LIMIT ? OFFSET ?
            """, arguments: [limit, offset])
        guard !dates.isEmpty else { return [] }
        let marks = dates.map { _ in "?" }.joined(separator: ",")
        let dateArgs = StatementArguments(dates)
        // The newest briefing of each date (`fetchByDate`'s pick).
        let briefings = try Briefing.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY date ORDER BY created_at DESC, id DESC) AS pick
                FROM briefings WHERE date IN (\(marks))
            ) WHERE pick = 1
            """, arguments: dateArgs)
        let briefingByDate = Dictionary(briefings.map { ($0.date, $0) }) { first, _ in first }
        // The newest plan of each date (`DayPlanQueries.fetchByDate`'s pick).
        let plans = try DayPlan.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY plan_date ORDER BY id DESC) AS pick
                FROM day_plans WHERE plan_date IN (\(marks))
            ) WHERE pick = 1
            """, arguments: dateArgs)
        let planByDate = Dictionary(plans.map { ($0.planDate, $0) }) { first, _ in first }
        var counts: [Int64: (done: Int, total: Int)] = [:]
        if !plans.isEmpty {
            let planMarks = plans.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT day_plan_id, COUNT(*) AS total, SUM(status = 'done') AS done
                FROM day_plan_items WHERE day_plan_id IN (\(planMarks))
                GROUP BY day_plan_id
                """, arguments: StatementArguments(plans.map(\.id)))
            for row in rows {
                counts[row["day_plan_id"]] = (done: row["done"] ?? 0, total: row["total"])
            }
        }
        return dates.map { date in
            let briefing = briefingByDate[date]
            let plan = planByDate[date]
            let count = plan.flatMap { counts[$0.id] } ?? (done: 0, total: 0)
            let stamp = AutomationDates.parse(briefing?.createdAt) ?? plan?.generatedAt ?? Date(timeIntervalSince1970: 0)
            return InboxDayCard(
                date: date, briefing: briefing, plan: plan, planDone: count.done, planTotal: count.total, stamp: stamp)
        }
    }

    package static func fetchLatest(_ db: Database) throws -> Briefing? {
        try Briefing.fetchOne(
            db,
            sql: "SELECT * FROM briefings ORDER BY created_at DESC LIMIT 1"
        )
    }

    /// 1 when the newest briefing is unread, else 0: the Inbox badge's day-card term.
    package static func latestUnreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (SELECT read_at FROM briefings ORDER BY created_at DESC, id DESC LIMIT 1)
            WHERE read_at IS NULL OR read_at = ''
            """) ?? 0
    }

    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ? AND read_at IS NULL
                """,
            arguments: [id]
        )
    }

    /// Marks multiple briefings read in one write. No-op on empty input.
    package static func markRead(_ db: Database, ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: """
                UPDATE briefings SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id IN (\(placeholders)) AND read_at IS NULL
                """,
            arguments: StatementArguments(ids)
        )
    }

    package static func unreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM briefings WHERE read_at IS NULL"
        ) ?? 0
    }

    package static func maxID(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM briefings") ?? 0
    }

    package static func fetchNewSince(_ db: Database, afterID: Int) throws -> [Briefing] {
        try Briefing.fetchAll(
            db,
            sql: """
                SELECT * FROM briefings
                WHERE id > ?
                ORDER BY id ASC
                """,
            arguments: [afterID]
        )
    }
}
