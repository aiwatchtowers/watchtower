import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
private final class RecordingNotifier: AutomationRunNotifying {
    struct Notice: Equatable {
        let name: String
        let status: AutomationRunStatus
        let summary: String
        let error: String
        let automationID: Int64
        let runID: Int64
    }

    private(set) var notices: [Notice] = []

    func runFinished(
        name: String,
        status: AutomationRunStatus,
        summary: String,
        error: String,
        automationID: Int64,
        runID: Int64
    ) {
        notices.append(Notice(name: name, status: status, summary: summary, error: error,
                              automationID: automationID, runID: runID))
    }

    private(set) var disabledRunIDs: [Int64?] = []
    private(set) var failureCounts: [Int] = []

    func automationDisabled(name: String, reason: String, automationID: Int64, runID: Int64?) {
        disabledRunIDs.append(runID)
    }

    func automationsFailed(count: Int) {
        failureCounts.append(count)
    }
}

/// Quick run's activation and finish watch (spec §12.7, Review Focus 8).
@MainActor
final class QuickRunCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var notifier: RecordingNotifier!
    private var featureOn = true
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        notifier = RecordingNotifier()
        featureOn = true
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private func make(_ runner: FakeCLIRunner) -> (QuickRunCenter, AutomationsViewModel) {
        let now = self.now
        let cli = AutomationsCLI(runner: runner)
        let vm = AutomationsViewModel(dbPool: pool, cli: cli, now: { now }, sleep: { _ in })
        let center = QuickRunCenter(dbPool: pool, viewModel: vm, cli: cli, notifier: notifier) { [weak self] in
            self?.featureOn ?? false
        }
        return (center, vm)
    }

    private static func runJSON(_ runID: Int64, coalesced: Bool = false) -> Data {
        Data(#"{"run_id":\#(runID),"coalesced":\#(coalesced),"daemon_running":true}"#.utf8)
    }

    private func row(_ center: QuickRunCenter, _ id: Int64) throws -> QuickRunRow {
        center.reload()
        return try XCTUnwrap(center.rows.first { $0.id == id })
    }

    /// The daemon queues the run the CLI call asked for (after the palette read its row).
    private func queueRun(_ automationID: Int64, status: String = "queued") throws -> Int64 {
        try pool.write { db in try TestDatabase.insertAutomationRun(db, automationID: automationID, status: status) }
    }

    private func setStatus(_ runID: Int64, _ status: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE automation_runs SET status = ?, summary = 'done' WHERE id = ?",
                           arguments: [status, runID])
        }
    }

    func testRunnableRowRunsWithCLIArgs() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db, slug: "notes", name: "Notes") }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, vm) = make(runner)
        let notes = try row(center, id)
        XCTAssertEqual(notes.state, .runnable)
        let runID = try queueRun(id)
        XCTAssertEqual(runID, 1)
        let outcome = await center.activate(notes, origin: .palette)

        XCTAssertEqual(outcome, .started(runID: runID))
        XCTAssertEqual(runner.invocations, [["automations", "run", String(id), "--json"]])
        XCTAssertEqual(center.watched[runID], .init(automationID: id, name: "Notes", origin: .palette))
        XCTAssertTrue(center.hasWatchedRuns)
        XCTAssertEqual(vm.items.first?.activeRun?.id, runID, "the list was refreshed")
        XCTAssertEqual(center.rows.first?.state, .running(runID: runID))
    }

    func testConfirmRecipeRunsOnlyAfterRun() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertAutomation(db, slug: "release", name: "Release", triggerKind: "button",
                                              triggerSpec: #"{"button":{"label":"Release","confirm":true}}"#)
        }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, _) = make(runner)
        let release = try row(center, id)

        let outcome = await center.activate(release, origin: .tray)
        XCTAssertEqual(outcome, .askFirst)
        XCTAssertEqual(center.pendingConfirm, release)
        XCTAssertEqual(center.pendingOrigin, .tray, "the palette's sheet leaves it to the tray's alert")
        XCTAssertEqual(runner.invocations, [], "nothing runs before Run")

        center.cancelConfirm()
        XCTAssertNil(center.pendingConfirm)
        XCTAssertEqual(runner.invocations, [], "Cancel runs nothing")

        _ = await center.activate(release, origin: .tray)
        let runID = try queueRun(id)
        await center.confirmRun()
        XCTAssertEqual(runner.invocations, [["automations", "run", String(id), "--json"]])
        XCTAssertNil(center.pendingConfirm)
        XCTAssertEqual(center.watched[runID]?.origin, .tray)
    }

    func testDimmedRowOpensInsteadOfRunning() async throws {
        let (unconfirmed, disabled, broken) = try await pool.write { db -> (Int64, Int64, Int64) in
            (
                try TestDatabase.insertAutomation(db, slug: "a", name: "Unconfirmed", approvalHash: "h2",
                                                  confirmedHash: "h1"),
                try TestDatabase.insertAutomation(db, slug: "b", name: "Disabled", enabled: false),
                try TestDatabase.insertAutomation(db, slug: "c", name: "Broken", parseError: "line 1: bad")
            )
        }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, vm) = make(runner)
        var shownTab = 0
        center.showAutomationsTab = { shownTab += 1 }

        let first = await center.activate(try row(center, unconfirmed), origin: .palette)
        XCTAssertEqual(first, .openedConfirmation)
        XCTAssertEqual(vm.pendingConfirmID, unconfirmed, "the tab opens the confirmation sheet")
        XCTAssertEqual(vm.selectedID, unconfirmed)

        let second = await center.activate(try row(center, disabled), origin: .palette)
        XCTAssertEqual(second, .openedCard(disabled))
        XCTAssertEqual(vm.selectedID, disabled)

        let third = await center.activate(try row(center, broken), origin: .tray)
        XCTAssertEqual(third, .openedCard(broken))

        XCTAssertEqual(runner.invocations, [], "a dimmed row runs nothing")
        XCTAssertEqual(shownTab, 3)
        XCTAssertNil(center.pendingConfirm)
        XCTAssertFalse(center.hasWatchedRuns)
    }

    func testRunningRowOpensRun() async throws {
        let (id, runID) = try await pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            return (id, try TestDatabase.insertAutomationRun(db, automationID: id, status: "running"))
        }
        let runner = FakeCLIRunner()
        let (center, vm) = make(runner)
        let outcome = await center.activate(try row(center, id), origin: .palette)
        XCTAssertEqual(outcome, .openedRun(runID))
        XCTAssertEqual(vm.selectedID, id)
        XCTAssertEqual(vm.expandedRuns, [runID])
        XCTAssertEqual(runner.invocations, [])
    }

    func testFeatureOffRefusesWithoutCLI() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, _) = make(runner)
        let runnable = try row(center, id)
        featureOn = false

        let outcome = await center.activate(runnable, origin: .palette)
        XCTAssertEqual(outcome, .refused("Automations are turned off in Settings → Features"))
        XCTAssertEqual(center.lastError, "Automations are turned off in Settings → Features")
        XCTAssertEqual(runner.invocations, [])
    }

    func testCLIRefusalSurfacesStderr() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let stderr = "automations are turned off in Settings → Features; turn them on to run this\n"
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
        let (center, _) = make(runner)
        let outcome = await center.activate(try row(center, id), origin: .palette)
        let text = "automations are turned off in Settings → Features; turn them on to run this"
        XCTAssertEqual(outcome, .refused(text))
        XCTAssertEqual(center.lastError, text)
        XCTAssertFalse(center.hasWatchedRuns)
        XCTAssertEqual(runner.invocations.count, 1, "nothing is retried")
    }

    func testCoalescedRunIsWatched() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db, name: "Digest") }
        let runner = FakeCLIRunner(stdout: Self.runJSON(5, coalesced: true))
        let (center, _) = make(runner)
        let digest = try row(center, id)
        // A schedule queued run 5 after the palette read the row; the CLI coalesced into it.
        try await pool.write { db in
            for _ in 1...4 { try TestDatabase.insertAutomationRun(db, automationID: id) }
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "running")
        }
        let outcome = await center.activate(digest, origin: .palette)
        XCTAssertEqual(outcome, .coalesced(runID: 5))
        XCTAssertNotNil(center.watched[5])

        try setStatus(5, "succeeded")
        await center.checkWatched()
        XCTAssertEqual(notifier.notices, [.init(name: "Digest", status: .succeeded, summary: "done", error: "",
                                                automationID: id, runID: 5)])
    }

    func testWatchedRunReadByIDNotFromList() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let runner = FakeCLIRunner(stdout: Self.runJSON(5))
        let (center, vm) = make(runner)
        let picked = try row(center, id)
        try await pool.write { db in
            for _ in 1...4 { try TestDatabase.insertAutomationRun(db, automationID: id) }
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "running") // 5
        }
        _ = await center.activate(picked, origin: .palette)

        try setStatus(5, "failed")
        let newer = try await pool.write { db in
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "running")
        }
        vm.refresh()
        XCTAssertEqual(vm.items.first?.activeRun?.id, newer, "the list already shows the newer run")
        await center.checkWatched()
        await center.checkWatched()
        XCTAssertEqual(notifier.notices.map(\.runID), [5])
        XCTAssertEqual(notifier.notices.first?.status, .failed)
    }

    func testFinishNoticeOncePerWatchedRun() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, _) = make(runner)
        let picked = try row(center, id)
        let runID = try queueRun(id, status: "running")
        _ = await center.activate(picked, origin: .palette)

        await center.checkWatched()
        XCTAssertEqual(notifier.notices, [], "still running")
        try setStatus(runID, "succeeded")
        await center.checkWatched()
        await center.checkWatched()
        XCTAssertEqual(notifier.notices.count, 1)
        XCTAssertEqual(center.watched, [:])
    }

    /// #584 F1: the daemon disabled the automation during the watched run;
    /// the failure watch's "was disabled" notice is the one banner, so the
    /// quick-run notice never overwrites it.
    func testNoFinishNoticeWhenTheRunDisabledItsAutomation() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, _) = make(runner)
        let picked = try row(center, id)
        let runID = try queueRun(id, status: "running")
        _ = await center.activate(picked, origin: .palette)

        try await pool.write { db in
            try db.execute(sql: """
                UPDATE automations SET enabled = 0, disabled_reason = 'runaway script',
                    disabled_at = '2026-10-01T09:05:00Z' WHERE id = ?
                """, arguments: [id])
        }
        try setStatus(runID, "timed_out")
        await center.checkWatched()
        XCTAssertEqual(notifier.notices, [])
        XCTAssertEqual(center.watched, [:])
    }

    func testWatchDropsVanishedRunSilently() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, _) = make(runner)
        let picked = try row(center, id)
        let runID = try queueRun(id, status: "running")
        _ = await center.activate(picked, origin: .palette)

        try await pool.write { db in
            try db.execute(sql: "DELETE FROM automation_runs WHERE automation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM automations WHERE id = ?", arguments: [id])
        }
        await center.checkWatched()
        XCTAssertEqual(center.watched, [:])
        XCTAssertEqual(notifier.notices, [])
    }

    func testRunsNotStartedHereAreNotNotified() async throws {
        let (id, runID) = try await pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            return (id, try TestDatabase.insertAutomationRun(db, automationID: id, status: "running"))
        }
        let runner = FakeCLIRunner(stdout: Self.runJSON(runID))
        let (center, vm) = make(runner)
        // Started from the card (or a schedule), not from quick run.
        await vm.runNow(id)
        try setStatus(runID, "succeeded")
        await center.checkWatched()
        XCTAssertEqual(notifier.notices, [])
        XCTAssertFalse(center.hasWatchedRuns)
    }

    func testWatchSurvivesClosedPalette() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let runner = FakeCLIRunner(stdout: Self.runJSON(1))
        let (center, vm) = make(runner)
        let picked = try row(center, id)
        let runID = try queueRun(id, status: "running")
        _ = await center.activate(picked, origin: .palette)
        // The palette closed; the owner is on another tab.
        vm.setTabVisible(true)
        vm.setTabVisible(false)

        try setStatus(runID, "timed_out")
        await center.checkWatched()
        XCTAssertEqual(notifier.notices.map(\.status), [.timedOut])
    }
}
