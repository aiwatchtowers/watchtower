import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class DayPlanQueriesTests: XCTestCase {

    // MARK: - fetchByDate

    func testFetchByDateAndItems() throws {
        let db = try TestDatabase.create()
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let itemId = try db.write { db in
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planId, kind: "backlog",
                                               sourceType: "manual", title: "Drink water")
        }

        let plan = try db.read { db in
            try DayPlanQueries.fetchByDate(db, date: "2026-04-23")
        }
        XCTAssertEqual(plan?.userId, "U1")

        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        XCTAssertEqual(items.map(\.id), [itemId])
        XCTAssertEqual(items.first?.status, .pending)
    }

    // MARK: - cascade to task

    private func seedTaskItem(_ db: DatabaseQueue) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO targets (id, text, intent, status, priority, ownership, tags, sub_items, created_at, updated_at, period_start, period_end)
                VALUES (42, 'T', '', 'todo', 'medium', 'mine', '[]', '[]', datetime('now'), datetime('now'), date('now'), date('now'))
                """)
            let planId = try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
            return try TestDatabase.insertDayPlanItem(db, dayPlanID: planId, kind: "backlog",
                                                      sourceType: "task", sourceID: "42", title: "T")
        }
    }

    // MARK: - cascade markItemPending resets task to 'todo'

    // MARK: - addManualItem + reorderBacklog

    // MARK: - deleteItem guard for calendar items

    // MARK: - deleteItem removes non-calendar items

    // MARK: - fetchList

    func testFetchList() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-21")
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-22")
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let plans = try db.read { db in
            try DayPlanQueries.fetchList(db, limit: 2)
        }
        XCTAssertEqual(plans.count, 2)
        // Newest first
        XCTAssertEqual(plans[0].planDate, "2026-04-23")
        XCTAssertEqual(plans[1].planDate, "2026-04-22")
    }

    // MARK: - addManualItem sets correct source type and status

}
