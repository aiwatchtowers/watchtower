import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `ActionStripViewModel` unions pending agent-actions + due reminders for the
/// Dashboard's action strip. Lives in `WatchtowerCore` (composes `AgentActionFeed`,
/// `AgentActionQueries`, `ReminderQueries` — all Core types, no SwiftUI/AppState
/// dependency), so its tests belong in the fast `Tests/Core` target alongside
/// `AgentActionFeedTests`/`ReminderQueriesTests`.
@MainActor
final class ActionStripViewModelTests: XCTestCase {
    private func makePool() throws -> (DatabasePool, String) { try TestDatabase.createPool() }

    func testRefreshPopulatesActionAndReminderRows() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a", status: "pending")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        vm.refresh()

        XCTAssertEqual(vm.actionRows.map(\.turnID), ["a"])
        XCTAssertEqual(vm.reminderRows.map(\.messageRef), ["C1@1"])
        XCTAssertNil(vm.lastError)
    }

    func testMarkReminderDoneDropsItOnNextRefresh() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
            return db.lastInsertedRowID
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()
        XCTAssertEqual(vm.reminderRows.map(\.id), [id])

        vm.markReminderDone(id)

        XCTAssertTrue(vm.reminderRows.isEmpty, "markReminderDone must drop the reminder from the strip on refresh")
        XCTAssertNil(vm.lastError)
    }

    func testSnoozeReminderMovesItOutOfTheDueWindow() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
            return db.lastInsertedRowID
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        vm.refresh()
        XCTAssertEqual(vm.reminderRows.map(\.id), [id])

        vm.snoozeReminder(id, until: "2999-01-01T00:00:00Z")

        XCTAssertTrue(vm.reminderRows.isEmpty, "a reminder snoozed into the future must drop out of the due strip")
        XCTAssertNil(vm.lastError)
    }

    /// The CLI writes on its OWN connection (`AgentActionFeedTests.testApproveRefreshesRowsAfterCLI`'s
    /// precedent) — a second pool stands in for it, since the fake runner never touches the DB.
    func testApproveDelegatesToTheComposedAgentActionFeed() async throws {
        let (pool, path) = try makePool()
        defer { TestDatabase.cleanup(path: path) }
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db, conversationID: 1, status: "pending") }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: runner)
        vm.refresh()
        XCTAssertEqual(vm.actionRows.map(\.status), ["pending"])

        let otherPool = try DatabasePool(path: path)
        try await otherPool.write { db in
            try db.execute(sql: "UPDATE agent_actions SET status = 'applied' WHERE id = ?", arguments: [id])
        }
        await vm.approve(id)

        XCTAssertEqual(runner.invocations, [["actions", "approve", String(id), "--json"]])
        XCTAssertNil(vm.lastError)
        XCTAssertTrue(vm.actionRows.isEmpty, "an applied (terminal) row must drop out of fetchStrip's non-terminal filter")
    }
}
