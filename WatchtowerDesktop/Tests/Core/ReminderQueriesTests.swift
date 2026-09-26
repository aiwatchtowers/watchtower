import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class ReminderQueriesTests: XCTestCase {
    func testFetchDueReturnsOnlyPendingPast() throws {
        let dbq = try TestDatabase.create()
        try dbq.write { db in
            try db.execute(sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1','a','2000-01-01T00:00:00Z','pending')")
            try db.execute(sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C2@2','b','2999-01-01T00:00:00Z','pending')")
            try db.execute(sql: "INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C3@3','c','2000-01-01T00:00:00Z','done')")
        }
        let due = try dbq.read { try ReminderQueries.fetchDue($0, nowUTC: "2100-01-01T00:00:00Z") }
        XCTAssertEqual(due.map(\.messageRef), ["C1@1"])
        // The sidebar badge twin counts exactly the rows fetchDue returns.
        XCTAssertEqual(try dbq.read { try ReminderQueries.dueCount($0, nowUTC: "2100-01-01T00:00:00Z") }, 1)
        XCTAssertEqual(try dbq.read { try ReminderQueries.dueCount($0, nowUTC: "1999-01-01T00:00:00Z") }, 0)
    }

    func testMarkDoneRemovesFromDue() throws {
        let dbq = try TestDatabase.create()
        let id = try dbq.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','a','2000-01-01T00:00:00Z','pending')
                """)
            return db.lastInsertedRowID
        }

        try dbq.write { try ReminderQueries.markDone($0, id: id) }

        let due = try dbq.read { try ReminderQueries.fetchDue($0, nowUTC: "2100-01-01T00:00:00Z") }
        XCTAssertTrue(due.isEmpty, "a done reminder must drop out of the due set")
        let row = try dbq.read { try Reminder.fetchOne($0, sql: "SELECT * FROM reminders WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(row?.status, "done")
        XCTAssertNotEqual(row?.doneAt, "")
    }

    func testSnoozeBumpsRemindAt() throws {
        let dbq = try TestDatabase.create()
        let id = try dbq.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','a','2000-01-01T00:00:00Z','pending')
                """)
            return db.lastInsertedRowID
        }

        // Not yet due against a "now" before the new remind_at.
        try dbq.write { try ReminderQueries.snooze($0, id: id, until: "2999-01-01T00:00:00Z") }
        var due = try dbq.read { try ReminderQueries.fetchDue($0, nowUTC: "2100-01-01T00:00:00Z") }
        XCTAssertTrue(due.isEmpty, "a snoozed reminder must not be due before its new remind_at")

        due = try dbq.read { try ReminderQueries.fetchDue($0, nowUTC: "3000-01-01T00:00:00Z") }
        XCTAssertEqual(due.map(\.messageRef), ["C1@1"], "still pending, so due once its new remind_at has passed")
    }
}
