import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `automation_outputs` with `kind='inbox'` are the strip's third source
/// (STRIP-01 amended, spec §14.4): opening writes `read_at`, Done writes
/// `done_at`, Dismiss writes `dismissed_at`, nothing else; `refresh()` stays
/// a pure read (STRIP-02, amended in ask #475).
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

    func testStripListsOpenInboxOutputs() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let (unread, read, newer) = try await pool.write { db -> (Int64, Int64, Int64) in
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, doneAt: "2026-10-01T10:00:00Z"
            )
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, dismissedAt: "2026-10-01T10:00:00Z"
            )
            // Backfilled by the migration: done_at = read_at.
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID,
                readAt: "2026-10-01T10:00:00Z", doneAt: "2026-10-01T10:00:00Z"
            )
            let unread = try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, title: "Old", createdAt: "2026-10-01T09:00:00Z"
            )
            let read = try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, title: "Read",
                createdAt: "2026-10-01T12:00:00Z", readAt: "2026-10-01T13:00:00Z"
            )
            let newer = try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, title: "New", createdAt: "2026-10-02T09:00:00Z"
            )
            return (unread, read, newer)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.refresh()

        XCTAssertEqual(vm.outputRows.map(\.id), [newer, read, unread])
        XCTAssertEqual(vm.outputRows.map(\.isUnread), [true, false, true])
        XCTAssertEqual(vm.outputRows.first?.automationName, "Mail summary")
        XCTAssertEqual(vm.outputRows.first?.runID, seed.runID)
        XCTAssertEqual(vm.outputRows.first?.title, "New")
        XCTAssertNil(vm.lastError)
    }

    func testDoneWritesOnlyDoneAt() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let before = try outputRow(pool, id)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.refresh()

        await vm.markOutputDone(id)

        let fetched = try outputRow(pool, id)
        let after = try XCTUnwrap(fetched)
        XCTAssertNotNil(after["done_at"] as String?)
        XCTAssertNil(after["read_at"] as String?)
        XCTAssertNil(after["dismissed_at"] as String?)
        for column in after.columnNames where column != "done_at" {
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
        await vm.refresh()

        await vm.dismissOutput(id)

        let fetched = try outputRow(pool, id)
        let after = try XCTUnwrap(fetched)
        XCTAssertNotNil(after["dismissed_at"] as String?)
        XCTAssertNil(after["read_at"] as String?)
        XCTAssertNil(after["done_at"] as String?)
        for column in after.columnNames where column != "dismissed_at" {
            XCTAssertEqual(after[column] as DatabaseValue, before?[column] as DatabaseValue?, column)
        }
        XCTAssertTrue(vm.outputRows.isEmpty)
        XCTAssertNil(vm.lastError)
    }

    func testOpeningWritesOnlyReadAt() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let badge = { try await pool.read { db in try ActionStripViewModel.badgeCount(db, nowUTC: "2026-10-16T00:00:00Z") } }
        let badgeBefore = try await badge()
        let before = try outputRow(pool, id)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.refresh()

        await vm.select(.output(id))

        let fetched = try outputRow(pool, id)
        let after = try XCTUnwrap(fetched)
        XCTAssertNotNil(after["read_at"] as String?)
        XCTAssertNil(after["done_at"] as String?)
        XCTAssertNil(after["dismissed_at"] as String?)
        for column in after.columnNames where column != "read_at" {
            XCTAssertEqual(after[column] as DatabaseValue, before?[column] as DatabaseValue?, column)
        }
        XCTAssertEqual(vm.selection, .output(id))
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
        XCTAssertEqual(vm.outputRows.first?.isUnread, false)
        let badgeAfter = try await badge()
        XCTAssertEqual(badgeAfter, badgeBefore, "unread outputs are not in the badge (R1)")
        XCTAssertNil(vm.lastError)

        await vm.select(nil)
        await vm.select(.output(id))

        let again = try outputRow(pool, id)
        XCTAssertEqual(again, after, "opening a read card writes nothing")
    }

    func testDoneAndDismissClearTheirSelection() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let (first, second) = try await pool.write { db -> (Int64, Int64) in
            (try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID),
             try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID))
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.refresh()

        await vm.select(.output(first))
        await vm.markOutputDone(second)
        XCTAssertEqual(vm.selection, .output(first), "another card's Done keeps the selection")
        await vm.markOutputDone(first)
        XCTAssertNil(vm.selection)

        let third = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        await vm.refresh()
        await vm.select(.output(third))
        await vm.dismissOutput(third)
        XCTAssertNil(vm.selection)
        XCTAssertTrue(vm.outputRows.isEmpty)
    }

    /// Opening a card writes `read_at` under its own key: a Done pressed
    /// while that write still waits for the writer lands, it is not dropped.
    func testDoneWhileOpeningLands() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.refresh()
        // Hold the writer, so the opening write waits for it.
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try await pool.write { _ in
                started.signal()
                release.wait()
            }
        }
        await Task.detached { started.wait() }.value

        // The opening waits on the writer (its selection is set just before).
        let opening = Task { await vm.select(.output(id)) }
        await waitUntil { vm.selection == .output(id) }
        // Without its own key the Done would return here at once, dropped;
        // with it, the Done waits on the writer too.
        let done = Task { await vm.markOutputDone(id) }
        await waitUntil { vm.isWriting(output: id) }
        release.signal()
        try await holder.value
        await opening.value
        await done.value

        let row = try XCTUnwrap(try outputRow(pool, id))
        XCTAssertNotNil(row["done_at"] as String?, "the Done press was dropped")
        XCTAssertTrue(vm.outputRows.isEmpty)
        XCTAssertNil(vm.selection)
        XCTAssertNil(vm.lastError)
    }

    func testCardCarriesPressAndRecipeState() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let ids = try await pool.write { db -> (pressed: Int64, run: Int64, disabled: Int64, unconfirmed: Int64) in
            let live = try TestDatabase.insertAutomation(db, slug: "live", name: "Live")
            let run = try TestDatabase.insertAutomationRun(db, automationID: live)
            let pressRun = try TestDatabase.insertAutomationRun(db, automationID: live, trigger: "reply")
            let pressed = try TestDatabase.insertAutomationOutput(
                db, automationID: live, runID: run, createdAt: "2026-10-01T09:00:03Z",
                link: "https://example.com/a", actionsJSON: #"[{"label":"Yes","reply":"yes"}]"#,
                pressedAction: 0, pressedRunID: pressRun, pressedAt: "2026-10-01T09:10:00Z"
            )
            let off = try TestDatabase.insertAutomation(db, slug: "off", name: "Off", enabled: false)
            let offRun = try TestDatabase.insertAutomationRun(db, automationID: off)
            let disabled = try TestDatabase.insertAutomationOutput(
                db, automationID: off, runID: offRun, createdAt: "2026-10-01T09:00:02Z"
            )
            let new = try TestDatabase.insertAutomation(db, slug: "new", name: "New", confirmedHash: "")
            let newRun = try TestDatabase.insertAutomationRun(db, automationID: new)
            let unconfirmed = try TestDatabase.insertAutomationOutput(
                db, automationID: new, runID: newRun, createdAt: "2026-10-01T09:00:01Z"
            )
            return (pressed, pressRun, disabled, unconfirmed)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.refresh()

        let cards = Dictionary(uniqueKeysWithValues: vm.outputRows.map { ($0.id, $0) })
        let pressed = try XCTUnwrap(cards[ids.pressed])
        XCTAssertEqual(pressed.pressedAction, 0)
        XCTAssertEqual(pressed.pressedRunID, ids.run)
        XCTAssertEqual(pressed.link, "https://example.com/a")
        XCTAssertEqual(pressed.actionsJSON, #"[{"label":"Yes","reply":"yes"}]"#)
        XCTAssertNil(pressed.workbenchID)
        XCTAssertEqual(pressed.recipeState, .runnable)
        XCTAssertNil(cards[ids.disabled]?.pressedAction)
        XCTAssertNil(cards[ids.disabled]?.pressedRunID)
        XCTAssertEqual(cards[ids.disabled]?.recipeState, .disabled)
        XCTAssertEqual(cards[ids.unconfirmed]?.recipeState, .needsConfirmation)
    }

    func testFailedWriteKeepsCard() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        let id = try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
        }
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.refresh()
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_output_update BEFORE UPDATE ON automation_outputs
                BEGIN SELECT RAISE(ABORT, 'disk said no'); END
                """)
        }

        await vm.markOutputDone(id)
        XCTAssertEqual(vm.outputRows.map(\.id), [id])
        XCTAssertNotNil(vm.lastError)

        await vm.dismissOutput(id)
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

        await vm.refresh()
        await vm.refresh()

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

        await vm.refresh()

        XCTAssertTrue(vm.outputRows.isEmpty)
        let badge = try await pool.read { db in try ActionStripViewModel.badgeCount(db, nowUTC: "2026-10-16T00:00:00Z") }
        XCTAssertEqual(badge, 0)
    }

    func testInboxBadgeLeavesOutputsOut() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let seed = try await seedAutomation(pool)
        try await pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
            try TestDatabase.insertAutomationOutput(db, automationID: seed.automationID, runID: seed.runID)
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID,
                readAt: "2026-10-01T10:00:00Z", doneAt: "2026-10-01T10:00:00Z"
            )
            // Read but not done: still open.
            try TestDatabase.insertAutomationOutput(
                db, automationID: seed.automationID, runID: seed.runID, readAt: "2026-10-01T11:00:00Z"
            )
            try TestDatabase.insertAgentAction(db, status: "pending")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
        }

        let badge = try await pool.read { db in try ActionStripViewModel.badgeCount(db, nowUTC: "2026-10-16T00:00:00Z") }

        // 1 proposal + 1 due reminder; unread outputs leave the badge (R1, spec §6.1).
        XCTAssertEqual(badge, 2)
    }

    /// J13: a source whose table is missing (an older schema) counts 0; any
    /// other read error is thrown, not folded into 0.
    func testBadgeCountToleratesOnlyAMissingTable() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertAgentAction(db, status: "pending")
            try db.execute(sql: "DROP TABLE automation_outputs")
        }
        let badge = try await pool.read { db in try ActionStripViewModel.badgeCount(db, nowUTC: "2026-10-16T00:00:00Z") }
        XCTAssertEqual(badge, 1, "the missing automation_outputs table counts 0")

        XCTAssertEqual(try ActionStripViewModel.zeroIfTableMissing { 3 }, 3)
        XCTAssertThrowsError(try ActionStripViewModel.zeroIfTableMissing {
            throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "database disk image is malformed")
        })
        XCTAssertThrowsError(try ActionStripViewModel.zeroIfTableMissing {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "no such column: read_at")
        })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
