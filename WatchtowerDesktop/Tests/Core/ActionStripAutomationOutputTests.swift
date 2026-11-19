import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerInterface
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

    private func outputRow(_ pool: DatabasePool, _ id: Int64) throws -> Row? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM automation_outputs WHERE id = ?", arguments: [id])
        }
    }

    func testStripListsOpenInboxOutputs() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Mail summary's run 1 wrote 1 (done), 2 (dismissed), 3 (read and done:
        // the migration's backfill), 4 "Old" unread, 5 "Read" read, 6 "New" unread.
        let tower = try FeedCaseTransport.seeded("desktop_output_lists_open", pool: pool)
        let (unread, read, newer): (Int64, Int64, Int64) = (4, 5, 6)
        let seed = Seed(automationID: 1, runID: 1)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.follow(tower)

        XCTAssertEqual(vm.outputRows.map(\.id), [newer, read, unread])
        XCTAssertEqual(vm.outputRows.map(\.isUnread), [true, false, true])
        XCTAssertEqual(vm.outputRows.first?.automationName, "Mail summary")
        XCTAssertEqual(vm.outputRows.first?.runID, seed.runID)
        XCTAssertEqual(vm.outputRows.first?.title, "New")
        XCTAssertNil(vm.lastError)
    }

    func testDoneAndDismissClearTheirSelection() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Outputs 1 and 2; Go's feeds once 2, then 1, are done, 3 is written and dismissed.
        let tower = try FeedCaseTransport.seeded("desktop_output_two_closed_then_a_third", pool: pool)
        let seed = Seed(automationID: 1, runID: 1)
        let (first, second): (Int64, Int64) = (1, 2)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.followWriting(tower)

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

    /// Opening a card has a key of its own: a Done pressed while the
    /// opening's `inbox.act read` is under way is sent too, never dropped.
    func testDoneWhileOpeningLands() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Output 1, unread; Go's next feed once it is done.
        let tower = try FeedCaseTransport.seeded("desktop_output_done", pool: pool)
        let id: Int64 = 1
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.followWriting(tower)

        async let opening: Void = vm.select(.output(id))
        async let done: Void = vm.markOutputDone(id)
        _ = await (opening, done)

        XCTAssertEqual(Set(tower.acts.map(\.verb)), [.read, .done], "the Done press was dropped")
        XCTAssertTrue(vm.outputRows.isEmpty)
        XCTAssertNil(vm.selection)
        XCTAssertNil(vm.lastError)
    }

    func testCardCarriesPressAndRecipeState() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Live (1): output 1 of run 1, its "Yes" pressed by run 2; Off (2, disabled):
        // output 2; New (3, unconfirmed): output 3.
        let tower = try FeedCaseTransport.seeded("desktop_output_press_and_recipe_state", pool: pool)
        let ids: (pressed: Int64, run: Int64, disabled: Int64, unconfirmed: Int64) = (1, 2, 2, 3)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.follow(tower)

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

    func testRefreshIsAPureRead() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Output 1, its run's proposal and a due reminder.
        let tower = try FeedCaseTransport.seeded("desktop_output_with_run_proposal_and_reminder", pool: pool)
        let tables = ["agent_actions", "reminders", "automation_outputs", "automation_runs", "automations", "pipeline_runs",
                      "inbox_folders", "inbox_folder_state", "inbox_folder_routes"]
        let snapshot = {
            try await pool.read { db in
                try tables.map { table in
                    try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
                }
            }
        }
        let before = try await snapshot()
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())

        await vm.follow(tower)
        await vm.refresh()

        let after = try await snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(vm.outputRows.count, 1)
        XCTAssertEqual(vm.actionRows.count, 1)
        XCTAssertEqual(vm.reminderRows.count, 1)
    }

    // MARK: - The drawn version (Inbox builder A)

    /// A living card seeded at hash `h1`, the list read (drawn at `h1`), then
    /// rewritten by a later run to `h2` before the owner presses.
    private func livingCardRewrittenUnderTheView(_ pool: DatabasePool) async throws
        -> (ActionStripViewModel, Int64) {
        // Output 1 at h1; Go's next feed once a later run rewrote it to h2.
        let tower = try FeedCaseTransport.seeded("desktop_output_living_rewritten", pool: pool)
        let seed = Seed(automationID: 1, runID: 1)
        let id: Int64 = 1
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.followWriting(tower)
        // Go's guard: the drawn hash no longer matches, nothing is written.
        tower.actAnswer = ActResult(already: true)
        XCTAssertEqual(vm.outputRows.first?.contentHash, "h1")
        try await pool.write { db in
            let run = try TestDatabase.insertAutomationRun(db, automationID: seed.automationID)
            try TestDatabase.rewriteLivingOutput(db, id: id, runID: run, body: "- Thread B",
                                                 blocksJSON: #"{"v":1,"blocks":[]}"#, contentHash: "h2",
                                                 at: "2026-10-02T09:00:00Z")
        }
        return (vm, id)
    }

    /// Opening, Done and Dismiss on a card rewritten under the view mark
    /// nothing: the row keeps its new version open and unread, and the
    /// strip reads it again instead of clearing it. (Each press starts from
    /// a list drawn at `h1`: after any press's re-read the list shows `h2`.)
    func testWritesOnRewrittenCardRereadInsteadOfClearing() async throws {
        for press in ["open", "done", "dismiss"] {
            let (pool, path) = try TestDatabase.createPool()
            defer { TestDatabase.cleanup(path: path) }
            let (vm, id) = try await livingCardRewrittenUnderTheView(pool)
            vm.selection = .output(id)
            switch press {
            case "open": await vm.select(.output(id))
            case "done": await vm.markOutputDone(id)
            default: await vm.dismissOutput(id)
            }

            let row = try XCTUnwrap(outputRow(pool, id))
            XCTAssertNil(row["read_at"] as String?, press)
            XCTAssertNil(row["done_at"] as String?, press)
            XCTAssertNil(row["dismissed_at"] as String?, press)
            XCTAssertEqual(vm.outputRows.map(\.id), [id], "\(press): the card is still listed")
            XCTAssertEqual(vm.outputRows.first?.contentHash, "h2", "\(press): read again, the new version")
            XCTAssertEqual(vm.outputRows.first?.isUnread, true, press)
            XCTAssertEqual(vm.selection, .output(id), "\(press): still shown")
            XCTAssertNil(vm.lastError, press)
        }
    }

    /// With the drawn hash the opening and Done are sent at it; the card
    /// leaves once Go's Done landed.
    func testDoneWithTheDrawnHashMarksOnce() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        // Living output 1 at h1; Go's next feed once it is done.
        let tower = try FeedCaseTransport.seeded("desktop_output_living_done", pool: pool)
        let id: Int64 = 1
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        await vm.followWriting(tower)
        await vm.select(.output(id))

        await vm.markOutputDone(id)

        XCTAssertEqual(tower.acts.map(\.verb), [.read, .done])
        XCTAssertEqual(tower.acts.map(\.params.contentHash), ["h1", "h1"])
        XCTAssertTrue(vm.outputRows.isEmpty)
        XCTAssertNil(vm.selection)
    }
}
