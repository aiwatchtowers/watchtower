import Foundation
import GRDB

enum DayPlanQueries {

    // MARK: - Reads

    /// Fetch the plan for today's date (local time zone, "yyyy-MM-dd").
    static func fetchToday(_ db: Database) throws -> DayPlan? {
        let today = Self.todayDateString()
        return try DayPlan.fetchOne(
            db,
            sql: "SELECT * FROM day_plans WHERE plan_date = ? ORDER BY id DESC LIMIT 1",
            arguments: [today]
        )
    }

    /// Fetch the plan for a specific date string ("yyyy-MM-dd").
    static func fetchByDate(_ db: Database, date: String) throws -> DayPlan? {
        return try DayPlan.fetchOne(
            db,
            sql: "SELECT * FROM day_plans WHERE plan_date = ? ORDER BY id DESC LIMIT 1",
            arguments: [date]
        )
    }

    /// Fetch the most recent plans, newest first.
    static func fetchList(_ db: Database, limit: Int = 30) throws -> [DayPlan] {
        return try DayPlan.fetchAll(
            db,
            sql: "SELECT * FROM day_plans ORDER BY plan_date DESC LIMIT ?",
            arguments: [limit]
        )
    }

    /// Fetch all items belonging to a plan, ordered by kind (timeblock first) then order_index.
    static func fetchItems(_ db: Database, planId: Int64) throws -> [DayPlanItem] {
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

    /// Mark a day plan item as done. If cascadeToTask is true and the item's source is a task,
    /// also sets that task's status to 'done' atomically.
    static func markItemDone(_ db: Database, itemId: Int64, cascadeToTask: Bool) throws {
        try db.execute(
            sql: """
                UPDATE day_plan_items
                SET status = 'done', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [itemId]
        )
        if cascadeToTask {
            try cascadeTaskStatus(db, itemId: itemId, taskStatus: "done")
        }
    }

    /// Mark a day plan item as pending. If cascadeToTask is true and the item's source is a task,
    /// resets that task's status back to 'todo' atomically.
    static func markItemPending(_ db: Database, itemId: Int64, cascadeToTask: Bool) throws {
        try db.execute(
            sql: """
                UPDATE day_plan_items
                SET status = 'pending', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [itemId]
        )
        if cascadeToTask {
            try cascadeTaskStatus(db, itemId: itemId, taskStatus: "todo")
        }
    }

    // MARK: - Delete

    /// Delete a day plan item. Calendar items are silently skipped (defense-in-depth).
    static func deleteItem(_ db: Database, itemId: Int64) throws {
        try db.execute(
            sql: "DELETE FROM day_plan_items WHERE id = ? AND source_type != 'calendar'",
            arguments: [itemId]
        )
    }

    // MARK: - Reorder

    /// Reassign order_index values for backlog items in the given order.
    /// Each id at position i gets order_index = i. All updates run in one transaction batch.
    static func reorderBacklog(_ db: Database, planId: Int64, orderedIds: [Int64]) throws {
        for (index, itemId) in orderedIds.enumerated() {
            try db.execute(
                sql: """
                    UPDATE day_plan_items
                    SET order_index = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE id = ? AND day_plan_id = ?
                    """,
                arguments: [index, itemId, planId]
            )
        }
    }

    // MARK: - Add Manual Item

    /// Insert a new manual item at the end of backlog (MAX order_index + 1, or 0 if empty).
    /// Returns the new row id.
    @discardableResult
    static func addManualItem(
        _ db: Database,
        planId: Int64,
        kind: DayPlanItemKind,
        title: String,
        startTime: Date?,
        endTime: Date?
    ) throws -> Int64 {
        let nextIndex: Int = (try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(order_index) + 1, 0) FROM day_plan_items WHERE day_plan_id = ?",
            arguments: [planId]
        )) ?? 0

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let startStr: String? = startTime.map { fmt.string(from: $0) }
        let endStr: String? = endTime.map { fmt.string(from: $0) }

        try db.execute(
            sql: """
                INSERT INTO day_plan_items
                    (day_plan_id, kind, source_type, title, start_time, end_time,
                     status, order_index, tags)
                VALUES (?, ?, 'manual', ?, ?, ?, 'pending', ?, '[]')
                """,
            arguments: [planId, kind.rawValue, title, startStr, endStr, nextIndex]
        )
        return db.lastInsertedRowID
    }

    // MARK: - Mark Read

    /// Set read_at to now on the plan.
    static func markRead(_ db: Database, planId: Int64) throws {
        try db.execute(
            sql: """
                UPDATE day_plans
                SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [planId]
        )
    }

    // MARK: - Private Helpers

    /// If the item has source_type='task' and a valid Int64 source_id, update that task's status.
    private static func cascadeTaskStatus(_ db: Database, itemId: Int64, taskStatus: String) throws {
        // Fetch source_type and source_id for the item
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT source_type, source_id FROM day_plan_items WHERE id = ?",
            arguments: [itemId]
        ) else { return }

        let sourceType = row["source_type"] as String? ?? ""
        guard sourceType == "task",
              let sourceIdStr = row["source_id"] as String?,
              let taskId = Int64(sourceIdStr) else { return }

        try db.execute(
            sql: """
                UPDATE tasks
                SET status = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [taskStatus, taskId]
        )
    }

    static func todayDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}
