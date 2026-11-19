import Foundation
import GRDB

package enum DayPlanQueries {

    // MARK: - Reads

    /// Fetch the plan for today's date (local time zone, "yyyy-MM-dd").
    package static func fetchToday(_ db: Database) throws -> DayPlan? {
        let today = Self.todayDateString()
        return try DayPlan.fetchOne(
            db,
            sql: "SELECT * FROM day_plans WHERE plan_date = ? ORDER BY id DESC LIMIT 1",
            arguments: [today]
        )
    }

    /// Fetch the plan for a specific date string ("yyyy-MM-dd").
    package static func fetchByDate(_ db: Database, date: String) throws -> DayPlan? {
        return try DayPlan.fetchOne(
            db,
            sql: "SELECT * FROM day_plans WHERE plan_date = ? ORDER BY id DESC LIMIT 1",
            arguments: [date]
        )
    }

    /// Fetch the most recent plans, newest first.
    package static func fetchList(_ db: Database, limit: Int = 30) throws -> [DayPlan] {
        return try DayPlan.fetchAll(
            db,
            sql: "SELECT * FROM day_plans ORDER BY plan_date DESC LIMIT ?",
            arguments: [limit]
        )
    }

    /// Fetch all items belonging to a plan, ordered by kind (timeblock first) then order_index.
    package static func fetchItems(_ db: Database, planId: Int64) throws -> [DayPlanItem] {
        return try DayPlanItem.fetchAll(
            db,
            sql: """
                SELECT * FROM day_plan_items
                WHERE day_plan_id = ?
                ORDER BY
                    CASE kind WHEN 'timeblock' THEN 0 ELSE 1 END,
                    order_index,
                    id
                """,
            arguments: [planId]
        )
    }

    // MARK: - Item Status Mutations

    // MARK: - Delete

    // MARK: - Reorder

    // MARK: - Add Manual Item

    // MARK: - Private Helpers

    package static func todayDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}
