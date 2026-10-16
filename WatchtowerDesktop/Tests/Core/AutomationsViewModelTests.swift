import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A CLI double answering by subcommand (`args[1]`), optionally held at a
/// gate until the test opens it.
private final class ScriptedRunner: CLIRunnerProtocol, @unchecked Sendable {
    typealias Handler = @Sendable ([String]) throws -> Data

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [[String]] = []
    private var heldSubcommand: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpened = false

    var invocations: [[String]] {
        lock.withLock { recorded }
    }

    /// True once a held call is waiting at the gate.
    var isHolding: Bool {
        lock.withLock { gate != nil }
    }

    func on(_ subcommand: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[subcommand] = handler }
    }

    func hold(_ subcommand: String) {
        lock.withLock { heldSubcommand = subcommand }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            gateOpened = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func run(args: [String]) async throws -> Data {
        let sub = args.count > 1 ? args[1] : ""
        let (handler, held) = lock.withLock {
            recorded.append(args)
            return (handlers[sub], heldSubcommand == sub)
        }
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if gateOpened { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try handler?(args) ?? Data()
    }
}

/// An injected `sleep` that records each interval and waits until the test
/// lets the poll go on (or the poll task is cancelled).
@MainActor
private final class SteppedSleep {
    private(set) var intervals: [Duration] = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ interval: Duration) async {
        intervals.append(interval)
        let key = intervals.count
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[key] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.resume(key) }
        }
    }

    /// Lets the newest sleep return.
    func wake() {
        resume(intervals.count)
    }

    private func resume(_ key: Int) {
        waiters.removeValue(forKey: key)?.resume()
    }
}

@MainActor
private final class CountingNotifier: AutomationRunNotifying {
    private(set) var runIDs: [Int64] = []

    func runFinished(
        name: String,
        status: AutomationRunStatus,
        summary: String,
        error: String,
        automationID: Int64,
        runID: Int64
    ) {
        runIDs.append(runID)
    }
}

@MainActor
final class AutomationsViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var runner: ScriptedRunner!
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        runner = ScriptedRunner()
    }

    override func tearDown() async throws {
        runner.release()
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    /// Tests that never call `start()` never sleep.
    private func makeViewModel(sleep: @escaping (Duration) async -> Void = { _ in }) -> AutomationsViewModel {
        let now = self.now
        return AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), now: { now }, sleep: sleep)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    nonisolated private static func json(_ text: String) -> Data { Data(text.utf8) }

    nonisolated private static let failure = CLIRunnerError.nonZeroExit(code: 1, stderr: "automation 7 is not runnable: disabled\n")

    // MARK: - Reads

    /// The "New automation" chat is keyed by `newDraftID`: it stays the same
    /// until a draft is saved, so closing the sheet keeps the draft.
    func testNewDraftIDIsStableUntilANewDraftStarts() {
        let vm = makeViewModel()
        let first = vm.newDraftID
        XCTAssertEqual(vm.newDraftID, first)
        vm.startNewDraft()
        XCTAssertNotEqual(vm.newDraftID, first)
    }

    func testListAndBadgesFromDatabase() throws {
        try pool.write { db in
            try TestDatabase.insertAutomation(db, slug: "mail", name: "Mail triage", approvalHash: "h2",
                                              confirmedHash: "h1")
            try TestDatabase.insertAutomation(db, slug: "digest", name: "Digest", enabled: false)
            try TestDatabase.insertAutomation(db, slug: "gone", name: "Gone", removedAt: "2026-10-10T00:00:00Z")
        }
        let vm = makeViewModel()
        vm.refresh()
        XCTAssertEqual(vm.items.map(\.automation.name), ["Digest", "Mail triage"])
        XCTAssertEqual(vm.items.map(\.badges), [[.disabled], [.needsConfirmation]])
        XCTAssertNil(vm.lastError)
    }

    func testAttentionCountFeedsBadge() throws {
        try pool.write { db in
            try TestDatabase.insertAutomation(db, slug: "new", approvalHash: "h2", confirmedHash: "")
            let id = try TestDatabase.insertAutomation(db, slug: "ok")
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "waiting", waitingReason: "approval")
            try TestDatabase.insertAutomationRun(db, automationID: id, status: "waiting", waitingReason: "session")
        }
        let vm = makeViewModel()
        vm.refresh()
        XCTAssertEqual(vm.attentionCount, 2)

        try pool.write { db in try db.execute(sql: "UPDATE automations SET confirmed_hash = approval_hash") }
        vm.refresh()
        XCTAssertEqual(vm.attentionCount, 1)
    }

    /// The daemon writes inbox outputs from another process; the poll is what
    /// tells the Inbox sidebar badge to re-read, and only when the count moved.
    func testInboxOutputCountChangeNotifiesTheInboxBadge() throws {
        let (automationID, runID) = try pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            return (id, try TestDatabase.insertAutomationRun(db, automationID: id))
        }
        let vm = makeViewModel()
        var notified = 0
        vm.onInboxOutputCountChanged = { notified += 1 }

        vm.refresh()
        XCTAssertEqual(notified, 0, "no outputs, no change")

        try pool.write { db in
            try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: runID)
            try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: runID, kind: "report")
        }
        vm.refresh()
        XCTAssertEqual(vm.inboxOutputCount, 1)
        XCTAssertEqual(notified, 1)

        vm.refresh()
        XCTAssertEqual(notified, 1, "an unchanged count does not refresh the badge again")
    }

    func testSelectLoadsCardAndToggleRunLoadsSteps() throws {
        let (id, runID) = try pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            let runID = try TestDatabase.insertAutomationRun(db, automationID: id)
            try TestDatabase.insertAutomationStep(db, runID: runID, seq: 1, kind: "tool", name: "list_jira_issues")
            try TestDatabase.insertAutomationOutput(db, automationID: id, runID: runID, kind: "report", title: "Weekly")
            try TestDatabase.insertAutomationGrant(db, automationID: id, tool: "create_jira_issue", grantHash: "h1")
            return (id, runID)
        }
        let vm = makeViewModel()
        vm.select(id)
        XCTAssertEqual(vm.runs[id]?.map(\.id), [runID])
        XCTAssertEqual(vm.reports[id]?.map(\.title), ["Weekly"])
        XCTAssertEqual(vm.grants[id]?.map(\.tool), ["create_jira_issue"])
        XCTAssertNil(vm.steps[runID])

        vm.toggleRun(runID)
        XCTAssertEqual(vm.expandedRuns, [runID])
        XCTAssertEqual(vm.steps[runID]?.map(\.name), ["list_jira_issues"])
        vm.toggleRun(runID)
        XCTAssertEqual(vm.expandedRuns, [])
    }

    func testOpenSelectsAndExpandsTheRun() throws {
        let (id, runID) = try pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            let runID = try TestDatabase.insertAutomationRun(db, automationID: id)
            try TestDatabase.insertAutomationStep(db, runID: runID, seq: 1, kind: "state", status: "ok")
            return (id, runID)
        }
        let vm = makeViewModel()
        vm.open(automationID: id, runID: runID)
        XCTAssertEqual(vm.selectedID, id)
        XCTAssertEqual(vm.expandedRuns, [runID])
        XCTAssertEqual(vm.steps[runID]?.count, 1)
    }

    // MARK: - Run now

    func testRunNowPassesCLIArgsAndRefreshes() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let pool = try XCTUnwrap(self.pool)
        runner.on("run") { _ in
            // The daemon queues the run from another process.
            try pool.write { db in _ = try TestDatabase.insertAutomationRun(db, automationID: id, status: "queued") }
            return Self.json(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#)
        }
        let vm = makeViewModel()
        vm.refresh()
        XCTAssertNil(vm.items.first?.activeRun)

        await vm.runNow(id)

        XCTAssertEqual(runner.invocations, [["automations", "run", String(id), "--json"]])
        XCTAssertNil(vm.busy[id])
        XCTAssertEqual(vm.items.first?.activeRun?.status, .queued, "refreshed after the call")
        XCTAssertNil(vm.lastError)
    }

    func testRunNowFailureShowsErrorAndKeepsList() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        runner.on("run") { _ in throw Self.failure }
        let vm = makeViewModel()
        vm.refresh()
        let before = vm.items

        await vm.runNow(id)

        XCTAssertEqual(vm.lastError, "automation 7 is not runnable: disabled")
        XCTAssertEqual(vm.items, before)
        XCTAssertNil(vm.busy[id])
    }

    func testRunNowMarksBusyWhileTheCallRuns() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        runner.on("run") { _ in Self.json(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#) }
        runner.hold("run")
        let vm = makeViewModel()
        let task = Task { await vm.runNow(id) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(vm.busy[id], .running)
        await vm.runNow(id) // a second click while busy calls nothing
        XCTAssertEqual(runner.invocations.count, 1)
        runner.release()
        await task.value
        XCTAssertNil(vm.busy[id])
    }

    /// Lifecycle rule (J9): Run now started, the owner leaves the tab and the
    /// card closes, the call finishes in the AppState-owned view model, and
    /// coming back shows the queued run with nothing left busy.
    func testRunNowSurvivesNavigation() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let pool = try XCTUnwrap(self.pool)
        runner.on("run") { _ in
            try pool.write { db in _ = try TestDatabase.insertAutomationRun(db, automationID: id, status: "queued") }
            return Self.json(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#)
        }
        runner.hold("run")
        let vm = makeViewModel()
        vm.setTabVisible(true)
        vm.select(id)

        let task = Task { await vm.runNow(id) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(vm.busy[id], .running)

        vm.setTabVisible(false)
        vm.select(nil)
        runner.release()
        await task.value

        vm.setTabVisible(true)
        vm.select(id)
        XCTAssertNil(vm.busy[id])
        XCTAssertEqual(vm.items.first?.activeRun?.status, .queued)
        XCTAssertNil(vm.lastError)
    }

    /// J13: a failed read of the list is cleared by the next read that
    /// works; a CLI failure is not cleared by the refresh after it.
    func testReadErrorClearsOnTheNextGoodReadCLIErrorStays() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let vm = makeViewModel()
        try await pool.write { db in try db.execute(sql: "ALTER TABLE automations RENAME TO automations_away") }
        vm.refresh()
        XCTAssertTrue(vm.lastError?.hasPrefix("Could not read automations") ?? false, "\(String(describing: vm.lastError))")
        try await pool.write { db in try db.execute(sql: "ALTER TABLE automations_away RENAME TO automations") }
        vm.refresh()
        XCTAssertNil(vm.lastError, "the next good read clears a read error")

        runner.on("run") { _ in throw Self.failure }
        await vm.runNow(id)
        XCTAssertEqual(vm.lastError, "automation 7 is not runnable: disabled")
        vm.refresh()
        XCTAssertEqual(vm.lastError, "automation 7 is not runnable: disabled", "a CLI failure stays")
    }

    // MARK: - Dry run

    private func seedDryRun() throws -> Int64 {
        try pool.write { db in
            let id = try TestDatabase.insertAutomation(db, approvalHash: "h2", confirmedHash: "")
            // Pad run ids so the dry run is run 12.
            for _ in 0..<11 { try TestDatabase.insertAutomationRun(db, automationID: id) }
            let dry = try TestDatabase.insertAutomationRun(db, automationID: id, trigger: "dry_run")
            XCTAssertEqual(dry, 12)
            try TestDatabase.insertAutomationStep(db, runID: 12, seq: 1, kind: "tool", name: "list_jira_issues")
            try TestDatabase.insertAutomationStep(db, runID: 12, seq: 2, kind: "output", name: "inbox",
                                                  argsJSON: #"{"title":"Two tickets"}"#, status: "dry_run")
            try TestDatabase.insertAutomationStep(db, runID: 12, seq: 3, kind: "state", status: "dry_run")
            return id
        }
    }

    private func answerDryRun() {
        runner.on("dry-run") { _ in
            Self.json(#"{"run_id":12,"status":"succeeded","error":"","input_tokens":100,"output_tokens":20}"#)
        }
    }

    nonisolated private static let dryRunLines = ["Read list_jira_issues", "Would post to Inbox: Two tickets", "Would save state"]

    func testDryRunRendersLinesFromStepsOfReturnedRun() async throws {
        let id = try seedDryRun()
        answerDryRun()
        let vm = makeViewModel()

        await vm.dryRun(id)

        XCTAssertEqual(runner.invocations, [["automations", "dry-run", String(id), "--json"]])
        XCTAssertEqual(vm.dryRuns[id], .done(runID: 12, lines: Self.dryRunLines, tokens: 120, status: "succeeded"))
        XCTAssertNil(vm.busy[id])
    }

    func testDryRunFailureIsShownOnTheCard() async throws {
        let id = try seedDryRun()
        runner.on("dry-run") { _ in throw Self.failure }
        let vm = makeViewModel()

        await vm.dryRun(id)

        XCTAssertEqual(vm.dryRuns[id], .failed("automation 7 is not runnable: disabled"))
        XCTAssertNil(vm.busy[id])
    }

    /// J11: the dry run ran (and spent tokens) but its steps could not be
    /// read: the card says it finished, not that it failed.
    func testDryRunStepsReadFailureSaysTheRunFinished() async throws {
        let id = try seedDryRun()
        let pool = try XCTUnwrap(self.pool)
        runner.on("dry-run") { _ in
            try pool.write { db in try db.execute(sql: "ALTER TABLE automation_run_steps RENAME TO steps_away") }
            return Self.json(#"{"run_id":12,"status":"succeeded","error":"","input_tokens":100,"output_tokens":20}"#)
        }
        let vm = makeViewModel()

        await vm.dryRun(id)

        guard case let .failed(message) = vm.dryRuns[id] else {
            return XCTFail("got \(String(describing: vm.dryRuns[id]))")
        }
        XCTAssertTrue(message.hasPrefix("Dry run finished (succeeded, 120 tokens); could not load its steps: "), message)
        XCTAssertNil(vm.busy[id])
    }

    func testDryRunSurvivesNavigation() async throws {
        let id = try seedDryRun()
        answerDryRun()
        runner.hold("dry-run")
        let vm = makeViewModel()
        vm.setTabVisible(true)
        vm.select(id)

        let task = Task { await vm.dryRun(id) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(vm.dryRuns[id], .running)
        XCTAssertEqual(vm.busy[id], .dryRunning)

        // The owner leaves the tab and the card closes.
        vm.setTabVisible(false)
        vm.select(nil)

        runner.release()
        await task.value

        vm.setTabVisible(true)
        vm.select(id)
        XCTAssertEqual(vm.dryRuns[id], .done(runID: 12, lines: Self.dryRunLines, tokens: 120, status: "succeeded"))
        XCTAssertNil(vm.busy[id])
    }

    // MARK: - Enable, delete, cancel

    func testRerunPassesRerunOf() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        runner.on("run") { _ in Self.json(#"{"run_id":10,"coalesced":false,"daemon_running":true}"#) }
        let vm = makeViewModel()
        await vm.rerun(id, runID: 4)
        XCTAssertEqual(runner.invocations, [["automations", "run", String(id), "--rerun-of", "4", "--json"]])
        XCTAssertNil(vm.busy[id])
        XCTAssertNil(vm.lastError)
    }

    func testLoadDetailReadsShowJSONAndKeepsItOnFailure() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        runner.on("show") { _ in
            Self.json(#"{"id":\#(id),"slug":"digest","scope":"personal","path":"/tmp/acme/digest.md","#
                + #""name":"Digest","description":"Reads **mail**.","enabled":true,"runnable":false,"#
                + #""needs_confirmation":true,"widening":["llm:light"],"#
                + #""changes":[{"field":"trigger","old":"a","new":"b"}],"changes_known":true}"#)
        }
        let vm = makeViewModel()
        await vm.loadDetail(id)
        XCTAssertEqual(runner.invocations, [["automations", "show", String(id), "--json"]])
        XCTAssertEqual(vm.details[id]?.description, "Reads **mail**.")
        XCTAssertEqual(vm.details[id]?.widening, ["llm:light"])
        XCTAssertEqual(vm.details[id]?.changes.map(\.field), ["trigger"])
        XCTAssertNil(vm.detailErrors[id])

        runner.on("show") { _ in throw Self.failure }
        await vm.loadDetail(id)
        XCTAssertEqual(vm.details[id]?.name, "Digest", "a failed read keeps the previous detail")
        XCTAssertEqual(vm.detailErrors[id], "automation 7 is not runnable: disabled")
    }

    /// Leaving the card (or switching rows fast) cancels the read: that is
    /// not an error to show on the card.
    func testLoadDetailIgnoresCancellation() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        runner.on("show") { _ in throw CancellationError() }
        let vm = makeViewModel()
        await vm.loadDetail(id)
        XCTAssertNil(vm.detailErrors[id])
        XCTAssertNil(vm.details[id])
        XCTAssertNil(vm.lastError)
    }

    /// The newest run opens expanded once; a collapse by the owner sticks
    /// across card appearances until another run becomes the newest.
    func testNewestRunExpandsOnlyTheFirstTimeItIsNewest() throws {
        let (id, otherID, runID) = try pool.write { db -> (Int64, Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            let otherID = try TestDatabase.insertAutomation(db, slug: "other")
            let runID = try TestDatabase.insertAutomationRun(db, automationID: id)
            return (id, otherID, runID)
        }
        let vm = makeViewModel()
        vm.select(id)
        vm.expandNewestRun(id)
        XCTAssertEqual(vm.expandedRuns, [runID])

        vm.toggleRun(runID)
        vm.expandNewestRun(id)
        XCTAssertEqual(vm.expandedRuns, [], "the owner's collapse sticks")

        vm.select(otherID)
        vm.select(id)
        vm.expandNewestRun(id)
        XCTAssertEqual(vm.expandedRuns, [], "coming back to the card does not re-expand it")

        let newer = try pool.write { db in
            try TestDatabase.insertAutomationRun(db, automationID: id, queuedAt: "2026-10-16T13:00:00Z")
        }
        vm.refresh()
        XCTAssertEqual(vm.runs[id]?.first?.id, newer)
        vm.expandNewestRun(id)
        XCTAssertEqual(vm.expandedRuns, [newer], "a run that becomes the newest opens once")
    }

    func testSetEnabledArgs() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        let vm = makeViewModel()
        await vm.setEnabled(id, false)
        await vm.setEnabled(id, true)
        XCTAssertEqual(runner.invocations, [["automations", "disable", String(id)], ["automations", "enable", String(id)]])
        XCTAssertNil(vm.busy[id])
    }

    func testDeleteRemovesAfterSuccessOnly() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db) }
        runner.on("delete") { _ in throw Self.failure }
        let vm = makeViewModel()
        vm.select(id)

        await vm.delete(id)

        XCTAssertEqual(vm.items.map(\.id), [id], "a failed delete keeps the row")
        XCTAssertEqual(vm.selectedID, id)
        XCTAssertEqual(vm.lastError, "automation 7 is not runnable: disabled")

        let pool = try XCTUnwrap(self.pool)
        runner.on("delete") { _ in
            try pool.write { db in try db.execute(sql: "DELETE FROM automations WHERE id = ?", arguments: [id]) }
            return Data()
        }
        await vm.delete(id)

        XCTAssertEqual(runner.invocations.last, ["automations", "delete", String(id)])
        XCTAssertEqual(vm.items, [])
        XCTAssertNil(vm.selectedID)
        XCTAssertNil(vm.runs[id])
        XCTAssertNil(vm.busy[id])
    }

    func testCancelMarksTheOwningAutomationBusy() async throws {
        let (id, runID) = try await pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            return (id, try TestDatabase.insertAutomationRun(db, automationID: id, status: "running"))
        }
        runner.hold("cancel")
        let vm = makeViewModel()
        vm.refresh()
        let task = Task { await vm.cancel(runID: runID) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(vm.busy[id], .cancelling)
        runner.release()
        await task.value
        XCTAssertEqual(runner.invocations, [["automations", "cancel", String(runID)]])
        XCTAssertNil(vm.busy[id])
    }

    // MARK: - Poll

    func testPollIntervalFollowsActiveRuns() async throws {
        let runID = try await pool.write { db in
            let id = try TestDatabase.insertAutomation(db)
            return try TestDatabase.insertAutomationRun(db, automationID: id, status: "running")
        }
        let sleeper = SteppedSleep()
        let vm = makeViewModel { await sleeper.sleep($0) }
        vm.start()
        defer { vm.stop() }

        await waitUntil { sleeper.intervals.count == 1 }
        XCTAssertEqual(sleeper.intervals, [.seconds(2)], "a running run polls fast")

        try await pool.write { db in
            try db.execute(sql: "UPDATE automation_runs SET status = 'succeeded' WHERE id = ?", arguments: [runID])
        }
        sleeper.wake()
        await waitUntil { sleeper.intervals.count == 2 }
        XCTAssertEqual(sleeper.intervals.last, .seconds(60), "the run ended and the tab is hidden: badge cadence")
        XCTAssertNil(vm.items.first?.activeRun)
    }

    func testTabVisibilityChangesTheCadenceAtOnce() async throws {
        try await pool.write { db in _ = try TestDatabase.insertAutomation(db) }
        let sleeper = SteppedSleep()
        let vm = makeViewModel { await sleeper.sleep($0) }
        vm.start()
        defer { vm.stop() }
        await waitUntil { sleeper.intervals.count == 1 }
        XCTAssertEqual(sleeper.intervals, [.seconds(60)])

        vm.setTabVisible(true)
        await waitUntil { sleeper.intervals.count == 2 }
        XCTAssertEqual(sleeper.intervals.last, .seconds(10))
    }

    /// Quick run's finish watch rides this poll: each tick checks the
    /// watched runs, the cadence is 2 s while one is watched, and once it
    /// ended (tab hidden) the badge cadence is back.
    func testPollChecksWatchedRuns() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db, name: "Notes") }
        let pool = try XCTUnwrap(self.pool)
        runner.on("run") { _ in
            // The daemon queues the run from another process.
            let runID = try pool.write { db in try TestDatabase.insertAutomationRun(db, automationID: id, status: "queued") }
            return Self.json(#"{"run_id":\#(runID),"coalesced":false,"daemon_running":true}"#)
        }
        let runID: Int64 = 1
        let sleeper = SteppedSleep()
        let vm = makeViewModel { await sleeper.sleep($0) }
        let notifier = CountingNotifier()
        let center = QuickRunCenter(dbPool: pool, viewModel: vm, cli: AutomationsCLI(runner: runner),
                                    notifier: notifier) { true }
        center.reload()
        let row = try XCTUnwrap(center.rows.first { $0.id == id })
        let outcome = await center.activate(row, origin: .palette)
        XCTAssertEqual(outcome, .started(runID: runID))
        // The daemon finished the run before the poll looked at it: no
        // active run is left, only the watch keeps the cadence fast.
        try await pool.write { db in
            try db.execute(sql: "UPDATE automation_runs SET status = 'succeeded' WHERE id = ?", arguments: [runID])
        }
        vm.refresh()
        XCTAssertNil(vm.items.first?.activeRun)

        vm.start()
        defer { vm.stop() }
        await waitUntil { sleeper.intervals.count == 1 }
        XCTAssertEqual(sleeper.intervals, [.seconds(2)], "a watched run polls fast with the tab hidden")
        XCTAssertEqual(notifier.runIDs, [])

        sleeper.wake()
        await waitUntil { sleeper.intervals.count == 2 }
        XCTAssertEqual(notifier.runIDs, [runID], "the tick checked the watched run")
        XCTAssertFalse(center.hasWatchedRuns)
        XCTAssertEqual(sleeper.intervals.last, .seconds(60), "nothing watched, tab hidden: badge cadence")
    }

}
