import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `builtin_migrations` rows, as Go `db.RecordBuiltinMigration` writes them.
final class BuiltinUpgradeNoticeTests: XCTestCase {
    private func record(_ db: Database, _ id: String, _ status: String, _ error: String, _ at: String) throws {
        try db.execute(sql: """
            INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at) VALUES (?, ?, ?, 1, ?)
            """, arguments: [id, status, error, at])
    }

    func testUpgradeNoticeListsFailedOnly() throws {
        let queue = try TestDatabase.create()
        let notices = try queue.write { db in
            try record(db, "morning-brief", "failed", "config unreadable", "2026-10-22T07:00:00Z")
            try record(db, "done-one", "done", "", "2026-10-22T08:00:00Z")
            try record(db, "x-y", "failed", "boom", "2026-10-22T09:00:00Z")
            return try BuiltinUpgradeNotice.load(db)
        }
        XCTAssertEqual(notices.map(\.builtinID), ["x-y", "morning-brief"], "failed only, newest first")
        XCTAssertEqual(notices.last?.error, "config unreadable")
        XCTAssertEqual(notices.last?.updatedAt, AutomationDates.parse("2026-10-22T07:00:00Z"))
        XCTAssertEqual(notices.last?.title, "Couldn't move Morning brief to Automations")
        XCTAssertEqual(notices.first?.title, "Couldn't move x-y to Automations")
    }

    func testUpgradeNoticeNameFallsBackToTheID() {
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "morning-brief"), "Morning brief")
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "x-y"), "x-y")
    }

    /// Twin of Go `builtin.Entry.Name` for C3's built-ins and the watch recipes' move.
    func testNoticeNamesForC3Ids() {
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "track-my-threads"), "Track my threads")
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "idea-finder"), "Idea finder")
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "reactions"), "Reactions")
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "custom-tracks"), "your watched tracks")
        XCTAssertEqual(BuiltinUpgradeNotice(builtinID: "custom-tracks", error: "", updatedAt: .distantPast).title,
                       "Couldn't move your watched tracks to Automations")
        XCTAssertEqual(BuiltinUpgradeNotice.name(for: "acme-new"), "acme-new")
    }

    func testUpgradeNoticeOnASchemaWithoutTheTable() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: "DROP TABLE builtin_migrations")
            XCTAssertEqual(try BuiltinUpgradeNotice.load(db), [])
            // Any other error is not folded into "none".
            try db.execute(sql: "CREATE TABLE builtin_migrations (builtin_id TEXT)")
            XCTAssertThrowsError(try BuiltinUpgradeNotice.load(db))
        }
    }
}
