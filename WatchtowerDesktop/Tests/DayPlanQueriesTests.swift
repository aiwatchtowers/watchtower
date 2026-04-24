import XCTest
import GRDB
@testable import WatchtowerDesktop

final class DayPlanQueriesTests: XCTestCase {

    // MARK: - fetchByDate + markItemDone

    func testFetchByDateAndMarkDone() throws {
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

        try db.write { db in
            try DayPlanQueries.markItemDone(db, itemId: itemId, cascadeToTask: false)
        }
        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        XCTAssertEqual(items.first?.status, .done)
    }

    // MARK: - cascade to task

    func testCascadeToTask() throws {
        let db = try TestDatabase.create()
        // Seed task with id=42
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, text, intent, status, priority, ownership, tags, sub_items, created_at, updated_at)
                VALUES (42, 'T', '', 'todo', 'medium', 'mine', '[]', '[]', datetime('now'), datetime('now'))
                """)
        }
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let itemId = try db.write { db in
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planId, kind: "backlog",
                                               sourceType: "task", sourceID: "42", title: "T")
        }

        try db.write { db in
            try DayPlanQueries.markItemDone(db, itemId: itemId, cascadeToTask: true)
        }

        let taskStatus: String = try db.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id=42") ?? ""
        }
        XCTAssertEqual(taskStatus, "done")
    }

    // MARK: - cascade markItemPending resets task to 'todo'

    func testCascadeMarkItemPendingResetsTaskToTodo() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, text, intent, status, priority, ownership, tags, sub_items, created_at, updated_at)
                VALUES (10, 'Task', '', 'done', 'medium', 'mine', '[]', '[]', datetime('now'), datetime('now'))
                """)
        }
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let itemId = try db.write { db in
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planId, kind: "backlog",
                                               sourceType: "task", sourceID: "10",
                                               title: "Task", status: "done")
        }

        try db.write { db in
            try DayPlanQueries.markItemPending(db, itemId: itemId, cascadeToTask: true)
        }

        let taskStatus: String = try db.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id=10") ?? ""
        }
        XCTAssertEqual(taskStatus, "todo")

        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        XCTAssertEqual(items.first?.status, .pending)
    }

    // MARK: - addManualItem + reorderBacklog

    func testAddManualAndReorder() throws {
        let db = try TestDatabase.create()
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let id1 = try db.write { db in
            try DayPlanQueries.addManualItem(db, planId: planId, kind: .backlog,
                                             title: "A", startTime: nil, endTime: nil)
        }
        let id2 = try db.write { db in
            try DayPlanQueries.addManualItem(db, planId: planId, kind: .backlog,
                                             title: "B", startTime: nil, endTime: nil)
        }
        let id3 = try db.write { db in
            try DayPlanQueries.addManualItem(db, planId: planId, kind: .backlog,
                                             title: "C", startTime: nil, endTime: nil)
        }

        try db.write { db in
            try DayPlanQueries.reorderBacklog(db, planId: planId, orderedIds: [id3, id1, id2])
        }
        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        let backlog = items.filter { $0.kind == .backlog }.sorted { $0.orderIndex < $1.orderIndex }
        XCTAssertEqual(backlog.map(\.title), ["C", "A", "B"])
    }

    // MARK: - deleteItem guard for calendar items

    func testDeleteCalendarItemIsNoop() throws {
        let db = try TestDatabase.create()
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let calId = try db.write { db in
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planId, kind: "timeblock",
                                               sourceType: "calendar", sourceID: "ev1",
                                               title: "Meeting")
        }

        try db.write { db in
            try DayPlanQueries.deleteItem(db, itemId: calId)
        }
        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        XCTAssertEqual(items.count, 1, "calendar item should NOT be deleted")
    }

    // MARK: - deleteItem removes non-calendar items

    func testDeleteNonCalendarItem() throws {
        let db = try TestDatabase.create()
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let itemId = try db.write { db in
            try TestDatabase.insertDayPlanItem(db, dayPlanID: planId, kind: "backlog",
                                               sourceType: "manual", title: "Deletable")
        }

        try db.write { db in
            try DayPlanQueries.deleteItem(db, itemId: itemId)
        }
        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - markRead

    func testMarkRead() throws {
        let db = try TestDatabase.create()
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23", readAt: nil)
        }

        // Verify unread before
        let before = try db.read { db in
            try DayPlanQueries.fetchByDate(db, date: "2026-04-23")
        }
        XCTAssertNil(before?.readAt)

        try db.write { db in
            try DayPlanQueries.markRead(db, planId: planId)
        }

        let after = try db.read { db in
            try DayPlanQueries.fetchByDate(db, date: "2026-04-23")
        }
        XCTAssertNotNil(after?.readAt)
        XCTAssertTrue(after?.isRead == true)
    }

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

    func testAddManualItemDefaults() throws {
        let db = try TestDatabase.create()
        let planId = try db.write { db in
            try TestDatabase.insertDayPlan(db, userID: "U1", planDate: "2026-04-23")
        }
        let itemId = try db.write { db in
            try DayPlanQueries.addManualItem(db, planId: planId, kind: .backlog,
                                             title: "My Item", startTime: nil, endTime: nil)
        }

        let items = try db.read { db in
            try DayPlanQueries.fetchItems(db, planId: planId)
        }
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, itemId)
        XCTAssertEqual(item.sourceType, .manual)
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.kind, .backlog)
        XCTAssertEqual(item.title, "My Item")
        XCTAssertEqual(item.tags, "[]")
    }
}
