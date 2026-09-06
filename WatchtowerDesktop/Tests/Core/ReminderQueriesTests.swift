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
    }
}
