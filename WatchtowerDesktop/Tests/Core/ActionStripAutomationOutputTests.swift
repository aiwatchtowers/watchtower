import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `automation_outputs` with `kind='inbox'` are the strip's third source
/// (STRIP-01 amended, spec §14.4): Done writes `read_at`, Dismiss writes
/// `dismissed_at`, nothing else; `refresh()` stays a pure read (STRIP-02).
@MainActor
final class ActionStripAutomationOutputTests: XCTestCase {
    private struct Seed {
        let automationID: Int64
        let runID: Int64
    }

    private func seedAutomation(_ pool: DatabasePool) async throws -> Seed {
        try await pool.write { db in
            let automationID = try TestDatabase.insertAutomation(db, slug: "mail-summary", name: "Mail summary")
            let runID = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            return Seed(automationID: automationID, runID: runID)
        }
    }

    private func outputRow(_ pool: DatabasePool, _ id: Int64) throws -> Row? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM automation_outputs WHERE id = ?", arguments: [id])
        }
    }

    func testStripListsUnreadInboxOutputs() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let (unread, newer) = try await pool.write { db -> (Int64, Int64) in
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, readAt: "2026-10-01T10:00:00Z"
            )
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, dismissedAt: "2026-10-01T10:00:00Z"
            )
            let unread = try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, title: "Old", createdAt: "2026-10-01T09:00:00Z"
            )
            let newer = try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, title: "New", createdAt: "2026-10-02T09:00:00Z"
            )
            return (unread, newer)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()

        XCTAssertEqual(vm.outputRows.map(\.id), [newer, unread])
        XCTAssertEqual(vm.outputRows.first?.automationName, "Mail summary")
        XCTAssertEqual(vm.outputRows.first?.runID, seed.runID)
        XCTAssertEqual(vm.outputRows.first?.title, "New")
        XCTAssertNil(vm.lastError)
    }

    func testDoneWritesOnlyReadAt() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let before = try outputRow(pool, id)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()

        vm.markOutputDone(id)

        let fetched = try outputRow(pool, id)
        let after = try XCTUnwrap(fetched)
        XCTAssertNotNil(after["read_at"] as String?)
        XCTAssertNil(after["dismissed_at"] as String?)
        for column in after.columnNames where column != "read_at" {
            XCTAssertEqual(after[column] as DatabaseValue, before?[column] as DatabaseValue?, column)
        }
        XCTAssertTrue(vm.outputRows.isEmpty)
        XCTAssertNil(vm.lastError)
    }

    func testDismissWritesOnlyDismissedAt() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let before = try outputRow(pool, id)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()

        vm.dismissOutput(id)

        let fetched = try outputRow(pool, id)
        let after = try XCTUnwrap(fetched)
        XCTAssertNotNil(after["dismissed_at"] as String?)
        XCTAssertNil(after["read_at"] as String?)
        for column in after.columnNames where column != "dismissed_at" {
            XCTAssertEqual(after[column] as DatabaseValue, before?[column] as DatabaseValue?, column)
        }
        XCTAssertTrue(vm.outputRows.isEmpty)
        XCTAssertNil(vm.lastError)
    }

    func testFailedWriteKeepsCard() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_output_update BEFORE UPDATE ON automation_outputs
                BEGIN SELECT RAISE(ABORT, 'disk said no'); END
                """)
        }

        vm.markOutputDone(id)
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
        XCTAssertNotNil(vm.lastError)

        vm.dismissOutput(id)
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
        XCTAssertNotNil(vm.lastError)
    }

    func testRefreshIsAPureRead() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
            try TestDatabase.insertAgentAction(
                db, surface: "automation", conversationID: 0, contextType: "automation_run", contextID: String(seed.runID)
            )
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
        }
        let tables = ["agent_actions", "reminders", "automation_outputs", "automation_runs", "automations", "pipeline_runs"]
        let snapshot = {
            try await pool.read { db in
                try tables.map { table in
                    try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
                }
            }
        }
        let before = try await snapshot()
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()
        vm.refresh()

        let after = try await snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(vm.outputRows.count, 1)
        XCTAssertEqual(vm.actionRows.count, 1)
        XCTAssertEqual(vm.reminderRows.count, 1)
    }

    func testReportAndBriefingOutputsNotOnStrip() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID, kind: "report")
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID, kind: "briefing")
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()

        XCTAssertTrue(vm.outputRows.isEmpty)
        let badge = try await pool.read { db in ActionStripViewModel.badgeCount(db, nowUTC: "2026-10-16T00:00:00Z") }
        XCTAssertEqual(badge, 0)
    }

    func testInboxBadgeCountsOutputs() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, readAt: "2026-10-01T10:00:00Z"
            )
            try TestDatabase.insertAgentAction(db, status: "pending")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
        }

        let badge = try await pool.read { db in ActionStripViewModel.badgeCount(db, nowUTC: "2026-10-16T00:00:00Z") }

        // 1 proposal + 1 due reminder + 2 unread inbox outputs.
        XCTAssertEqual(badge, 4)
    }
}
