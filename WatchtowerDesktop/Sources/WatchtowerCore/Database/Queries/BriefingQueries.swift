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
    /// the plan's done/total item counts.
    package static func fetchDayCards(_ db: Database, limit: Int, offset: Int = 0) throws -> [InboxDayCard] {
        let dates = try String.fetchAll(db, sql: """
            SELECT date FROM (
                SELECT date AS date FROM briefings UNION SELECT plan_date AS date FROM day_plans
            ) ORDER BY date DESC LIMIT ? OFFSET ?
            """, arguments: [limit, offset])
        return try dates.map { date in
            let briefing = try fetchByDate(db, date: date)
            let plan = try DayPlanQueries.fetchByDate(db, date: date)
            var done = 0
            var total = 0
            if let plan {
                let items = try DayPlanQueries.fetchItems(db, planId: plan.id)
                total = items.count
                done = items.filter { $0.status == .done }.count
            }
            let stamp = AutomationDates.parse(briefing?.createdAt) ?? plan?.generatedAt ?? Date(timeIntervalSince1970: 0)
            return InboxDayCard(date: date, briefing: briefing, plan: plan, planDone: done, planTotal: total, stamp: stamp)
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
