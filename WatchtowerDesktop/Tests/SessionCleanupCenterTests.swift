import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A `SessionCleanupRunning` double: records every call's argv and child
/// environment, answers from `replies` in order (the last one repeats), and
/// can hold a call until `release()`. A call whose task was cancelled
/// throws `CancellationError` once released, as `ProcessCLIRunner`
/// terminates the CLI then.
final class FakeSessionCleanupRunner: SessionCleanupRunning, @unchecked Sendable {
    struct Call: Sendable {
        let args: [String]
        let environment: [String: String]
    }

    /// When true, each call waits for `release()`.
    var holdsCalls = false
    /// Runs on each call before it answers (a test writing what Go would).
    var onCall: (@Sendable (Call) -> Void)?

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var replies: [Result<Data, Error>]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var cancelled = 0

    init(replies: [Result<Data, Error>]) {
        self.replies = replies
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    /// The calls that ended cancelled (the CLI would have been terminated).
    var cancelledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func release() {
        lock.lock()
        let waiting = held
        held = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func runCleanupCommand(args: [String], environment: [String: String]) async throws -> Data {
        let call = Call(args: args, environment: environment)
        let reply = record(call)
        onCall?(call)
        if holdsCalls {
            await withCheckedContinuation { continuation in
                lock.lock()
                held.append(continuation)
                lock.unlock()
            }
        }
        if Task.isCancelled {
            lock.lock()
            cancelled += 1
            lock.unlock()
            throw CancellationError()
        }
        return try reply.get()
    }

    private func record(_ call: Call) -> Result<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return replies.count > 1 ? replies.removeFirst() : replies.first ?? .success(Data("{}".utf8))
    }
}

/// Go-shaped cleanup JSON for the tests (spec 2026-10-12-session-cleanup §4.1).
enum CleanupFixture {
    static let plan = Data("""
    {"session_id":9,"workbench_id":2,"mode":"plan","sweep":false,"default_branch":"main",
     "items":[
      {"key":"worktree:/tmp/example/.claude/worktrees/x","kind":"worktree","name":"x","branch":"feat/x",
       "bytes":2000000000,"bytes_known":true,"action":"remove","reason":"","detail":"","done":false,"error":""},
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"remove","done":false,"error":""},
      {"key":"worktree:/tmp/example/.claude/worktrees/y","kind":"worktree","name":"y","branch":"feat/y",
       "bytes":0,"bytes_known":true,"action":"keep","reason":"uncommitted_changes","done":false,"error":""}
     ],
     "removed_bytes":0,"removed_bytes_known":true,"summary":"","result_saved":false,"result_error":""}
    """.utf8)

    static let plannedKeys = ["worktree:/tmp/example/.claude/worktrees/x", "branch:feat/x"]

    static let emptyPlan = Data(#"{"session_id":9,"workbench_id":2,"mode":"plan","items":[]}"#.utf8)

    static let applied = Data("""
    {"session_id":9,"workbench_id":2,"mode":"apply",
     "items":[
      {"key":"worktree:/tmp/example/.claude/worktrees/x","kind":"worktree","name":"x","action":"remove","done":true,"error":""},
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"remove","done":true,"error":""}
     ],
     "removed_bytes":2000000000,"removed_bytes_known":true,
     "summary":"1 worktree, 1 branch removed (~2.0 GB)","result_saved":true,"result_error":""}
    """.utf8)

    /// The Delete dialog's plan while the session's terminal runs: its
    /// worktree is kept for a running process, the branch checked out in it
    /// with it; another branch is kept for unpushed commits.
    static let planBusy = Data("""
    {"session_id":9,"workbench_id":2,"mode":"plan","items":[
      {"key":"worktree:/tmp/example/.claude/worktrees/x","kind":"worktree","name":"x","branch":"feat/x",
       "action":"keep","reason":"process_running","detail":"process in use: claude pid 42"},
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"keep","reason":"checked_out"},
      {"key":"branch:feat/old","kind":"branch","name":"feat/old","action":"keep","reason":"unpushed_commits"}
    ]}
    """.utf8)

    /// The plan once the terminal closed: the worktree and its branch are
    /// free, and so is a branch the dialog never showed as removable.
    static let replanFree = Data("""
    {"session_id":9,"workbench_id":2,"mode":"plan","items":[
      {"key":"worktree:/tmp/example/.claude/worktrees/x","kind":"worktree","name":"x","branch":"feat/x",
       "bytes_known":true,"action":"remove"},
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"remove"},
      {"key":"branch:feat/old","kind":"branch","name":"feat/old","action":"remove"}
    ]}
    """.utf8)

    /// A removable item of a kind this build does not know, beside a branch.
    static let planWithUnknownKind = Data("""
    {"session_id":9,"workbench_id":2,"mode":"plan","items":[
      {"key":"gizmo:1","kind":"gizmo","name":"g","action":"remove"},
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"remove"}
    ]}
    """.utf8)

    static let planUnknownOnly = Data("""
    {"session_id":9,"workbench_id":2,"mode":"plan","items":[
      {"key":"gizmo:1","kind":"gizmo","name":"g","action":"remove"}
    ]}
    """.utf8)

    /// The apply removed the worktree but kept the branch: a commit landed
    /// while the dialog was open.
    static let appliedKeptBranch = Data("""
    {"session_id":9,"workbench_id":2,"mode":"apply","items":[
      {"key":"worktree:/tmp/example/.claude/worktrees/x","kind":"worktree","name":"x","action":"remove","done":true},
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"keep","reason":"unpushed_commits"}
    ],"summary":"1 worktree removed","result_saved":true}
    """.utf8)

    static let appliedWithError = Data("""
    {"session_id":9,"workbench_id":2,"mode":"apply",
     "items":[
      {"key":"branch:feat/x","kind":"branch","name":"feat/x","action":"remove","done":false,
       "error":"cannot lock ref"}
     ],
     "summary":"","result_saved":true,"result_error":""}
    """.utf8)
}

/// `SessionCleanupCenter` (board #535, spec 2026-10-12-session-cleanup
/// §4/§12): its argv, the child environment, phases across navigation.
@MainActor
final class SessionCleanupCenterTests: XCTestCase {
    /// Every scripted streamer a test made: tearDown ends their runs.
    private var streamers: [ScriptedCleanupStreamer] = []
    /// Real children a test started: stopped and reaped in tearDown.
    private var children: [SessionCleanupStream] = []

    override func tearDown() async throws {
        streamers.forEach { $0.finishAll() }
        streamers = []
        for child in children {
            child.stop()
            _ = await child.exit()
        }
        children = []
        try await super.tearDown()
    }

    private func streamedCenter() -> (SessionCleanupCenter, ScriptedCleanupStreamer) {
        let streamer = ScriptedCleanupStreamer()
        streamers.append(streamer)
        let center = SessionCleanupCenter(runner: nil, streamer: streamer)
        center.baseEnvironment = { ["PATH": "/usr/bin", SessionCleanupCenter.terminalSessionVariable: "7"] }
        return (center, streamer)
    }

    func testPlanPassesLiveSessions() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        let center = SessionCleanupCenter(runner: runner)
        center.liveSessionIDs = { [5, 9, 3] }

        await center.planCleanup(sessionID: 9, workbenchID: 2)
        await center.planCleanup(sessionID: 9, workbenchID: 2, closingSession: true)

        XCTAssertEqual(runner.calls.map(\.args), [
            ["workbench", "cleanup", "--session=9", "--workbench=2",
             "--live-session=3", "--live-session=5", "--live-session=9", "--json"],
            ["workbench", "cleanup", "--session=9", "--workbench=2",
             "--live-session=3", "--live-session=5", "--json"]
        ], "the Delete dialog's plan leaves out the session whose terminal it closes")
        guard case let .ready(plan) = center.cleanupPhase(for: .session(9)) else {
            return XCTFail("expected a ready plan, got \(center.cleanupPhase(for: .session(9)))")
        }
        XCTAssertEqual(plan.removableKeys, CleanupFixture.plannedKeys)
    }

    func testCleanupCallsDropTheTerminalSessionVariable() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let center = SessionCleanupCenter(runner: runner)
        center.baseEnvironment = {
            ["PATH": "/usr/bin:/bin", SessionCleanupCenter.terminalSessionVariable: "7", "HOME": "/tmp/example"]
        }

        await center.planCleanup(sessionID: 9, workbenchID: 2)
        _ = await center.applyCleanup(sessionID: 9, workbenchID: 2, items: CleanupFixture.plannedKeys)

        XCTAssertEqual(runner.calls.count, 2)
        for call in runner.calls {
            XCTAssertNil(call.environment[SessionCleanupCenter.terminalSessionVariable], "\(call.args)")
            XCTAssertEqual(call.environment["PATH"], "/usr/bin:/bin", "the rest of the environment is kept")
            XCTAssertEqual(call.environment["HOME"], "/tmp/example")
        }
    }

    /// The production runner hands the child exactly the environment given
    /// — what makes dropping the variable reach the CLI.
    func testProcessRunnerHandsTheChildTheGivenEnvironment() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/usr/bin/env")
        let data = try await runner.runCleanupCommand(args: [], environment: ["WT_PROBE": "1"])
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "WT_PROBE=1\n")
    }

    /// A plan started through `startPlan` belongs to the center: its
    /// caller — a sheet's task, cancelled when the page is left — going
    /// away neither stops the CLI nor fails the plan.
    func testPlanOutlivesItsCancelledCaller() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        runner.holdsCalls = true
        let center = SessionCleanupCenter(runner: runner)

        let caller = Task { await center.startPlan(sessionID: 9, workbenchID: 2).value }
        while runner.heldCount == 0 { await Task.yield() }
        caller.cancel()
        XCTAssertEqual(center.cleanupPhase(for: .session(9)), .planning)

        runner.release()
        await caller.value
        XCTAssertEqual(runner.cancelledCount, 0, "the CLI ran on")

        guard case let .ready(plan) = center.cleanupPhase(for: .session(9)) else {
            return XCTFail("expected the plan kept, got \(center.cleanupPhase(for: .session(9)))")
        }
        XCTAssertEqual(plan.removableKeys, CleanupFixture.plannedKeys)
    }

    /// A plan run directly in a task that is then cancelled leaves no
    /// phase behind — never `.failed(CancellationError)`.
    func testCancelledPlanIsNotAFailure() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        runner.holdsCalls = true
        let center = SessionCleanupCenter(runner: runner)

        let run = Task { await center.planCleanup(sessionID: 9, workbenchID: 2) }
        while runner.heldCount == 0 { await Task.yield() }
        run.cancel()
        runner.release()
        await run.value

        XCTAssertEqual(center.cleanupPhase(for: .session(9)), .idle)
    }

    /// Forgetting a scope stops the plan `startPlan` runs for it.
    func testForgetStopsAStartedPlan() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        runner.holdsCalls = true
        let center = SessionCleanupCenter(runner: runner)

        let run = center.startPlan(sessionID: 9, workbenchID: 2)
        while runner.heldCount == 0 { await Task.yield() }
        center.forgetCleanup(.session(9))
        runner.release()
        await run.value

        XCTAssertEqual(center.cleanupPhase(for: .session(9)), .idle)
        XCTAssertEqual(runner.cancelledCount, 1, "the CLI is stopped, not left to run")
    }

    /// A second plan for the same scope stops the first: one CLI child,
    /// never two lsof scans racing.
    func testStartingAPlanStopsTheOneRunning() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        runner.holdsCalls = true
        let center = SessionCleanupCenter(runner: runner)

        let first = center.startPlan(sessionID: 9, workbenchID: 2)
        while runner.heldCount < 1 { await Task.yield() }
        let second = center.startPlan(sessionID: 9, workbenchID: 2)
        while runner.heldCount < 2 { await Task.yield() }
        runner.release()
        await first.value
        await second.value

        XCTAssertEqual(runner.cancelledCount, 1, "the first plan was stopped")
        guard case .ready = center.cleanupPhase(for: .session(9)) else {
            return XCTFail("the second plan is ready, got \(center.cleanupPhase(for: .session(9)))")
        }
    }

    func testApplyWithoutItemsRunsNothing() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.applied)])
        let center = SessionCleanupCenter(runner: runner)

        let ok = await center.applyCleanup(sessionID: 9, workbenchID: 2, items: [])

        XCTAssertTrue(ok)
        XCTAssertTrue(runner.calls.isEmpty, "an apply without --item would remove everything eligible")
    }

    func testApplyNamesExactlyTheItems() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.applied)])
        let center = SessionCleanupCenter(runner: runner)
        center.liveSessionIDs = { [4] }

        let ok = await center.applyCleanup(sessionID: 9, workbenchID: 2, items: CleanupFixture.plannedKeys)

        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.map(\.args), [[
            "workbench", "cleanup", "--session=9", "--workbench=2", "--live-session=4", "--apply",
            "--item=worktree:/tmp/example/.claude/worktrees/x", "--item=branch:feat/x", "--json"
        ]])
        guard case let .done(result) = center.cleanupPhase(for: .session(9)) else {
            return XCTFail("expected done")
        }
        XCTAssertEqual(result.summary, "1 worktree, 1 branch removed (~2.0 GB)")
        XCTAssertNil(center.failureText(for: .session(9)))
    }

    func testItemErrorIsAFailure() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.appliedWithError)])
        let center = SessionCleanupCenter(runner: runner)

        let ok = await center.applyCleanup(sessionID: 9, workbenchID: 2, items: ["branch:feat/x"])

        XCTAssertFalse(ok)
        XCTAssertEqual(center.failureText(for: .session(9)), "feat/x: cannot lock ref")
    }

    func testFailedRunShowsItsMessage() async {
        let runner = FakeSessionCleanupRunner(replies: [.failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "no git"))])
        let center = SessionCleanupCenter(runner: runner)

        await center.planCleanup(sessionID: 9, workbenchID: 2)

        guard case let .failed(message) = center.cleanupPhase(for: .session(9)) else {
            return XCTFail("expected failed")
        }
        XCTAssertTrue(message.contains("no git"), message)
    }

    func testWithoutABinaryEveryRunFails() async {
        let center = SessionCleanupCenter(runner: nil)

        let ok = await center.applyCleanup(sessionID: 9, workbenchID: 2, items: ["branch:feat/x"])

        XCTAssertFalse(ok)
        XCTAssertNotNil(center.failureText(for: .session(9)))
    }

    func testForgetKeepsAnApplyInFlight() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.applied)])
        runner.holdsCalls = true
        let center = SessionCleanupCenter(runner: runner)

        let applying = Task { await center.applyCleanup(sessionID: 9, workbenchID: 2, items: ["branch:feat/x"]) }
        while runner.heldCount == 0 { await Task.yield() }
        center.forgetCleanup(.session(9))
        await center.planCleanup(sessionID: 9, workbenchID: 2)
        XCTAssertEqual(center.cleanupPhase(for: .session(9)), .applying, "neither a forget nor a plan cuts in")

        runner.release()
        let ok = await applying.value
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testDeleteDialogOfferFollowsThePhase() throws {
        let plan = try JSONDecoder().decode(SessionCleanupPlan.self, from: CleanupFixture.plan)
        let empty = try JSONDecoder().decode(SessionCleanupPlan.self, from: CleanupFixture.emptyPlan)

        XCTAssertEqual(SessionDeleteCleanupOffer.message(.planning), "Checking what this session left…")
        XCTAssertFalse(SessionDeleteCleanupOffer.offersCleanup(.planning))
        let line = try XCTUnwrap(SessionDeleteCleanupOffer.message(.ready(plan)))
        XCTAssertTrue(line.hasPrefix("Also clean up: 1 worktree, 1 branch (~2.0 GB). Kept: 1 worktree — uncommitted changes."),
                      line)
        XCTAssertTrue(line.hasSuffix(SessionDeleteCleanupOffer.undoNote), "Undo cannot bring the worktrees back")
        XCTAssertTrue(SessionDeleteCleanupOffer.offersCleanup(.ready(plan)))
        XCTAssertNil(SessionDeleteCleanupOffer.message(.ready(empty)), "nothing removable: the dialog is as before")
        XCTAssertFalse(SessionDeleteCleanupOffer.offersCleanup(.ready(empty)))
        XCTAssertNil(SessionDeleteCleanupOffer.message(.idle))
        let unknownOnly = try JSONDecoder().decode(SessionCleanupPlan.self, from: CleanupFixture.planUnknownOnly)
        XCTAssertFalse(SessionDeleteCleanupOffer.offersCleanup(.ready(unknownOnly)),
                       "an item of an unknown kind is never shown, so never offered")
        XCTAssertNil(SessionDeleteCleanupOffer.message(.ready(unknownOnly)))
        let busy = try JSONDecoder().decode(SessionCleanupPlan.self, from: CleanupFixture.planBusy)
        XCTAssertTrue(SessionDeleteCleanupOffer.offersCleanup(.ready(busy)), "removed once the terminal closes")
        XCTAssertEqual(SessionDeleteCleanupOffer.message(.failed("boom")), "Could not check what this session left: boom")
    }

    // MARK: Streamed runs (board #1107, spec 2026-10-26 §6/§7)

    func testStreamedPlanArguments() async {
        let (center, streamer) = streamedCenter()
        center.liveSessionIDs = { [4] }

        center.startStreamedPlan(.workbench(2), workbenchID: 2)
        center.startStreamedPlan(.session(9), workbenchID: 2)
        await waitUntil("two runs") { streamer.runs.count == 2 }

        XCTAssertEqual(streamer.runs.map(\.args), [
            ["workbench", "cleanup", "--workbench=2", "--sweep", "--live-session=4", "--json", "--stream"],
            ["workbench", "cleanup", "--session=9", "--workbench=2", "--live-session=4", "--json", "--stream"]
        ])
        for run in streamer.runs {
            XCTAssertNil(run.environment[SessionCleanupCenter.terminalSessionVariable])
            XCTAssertEqual(run.environment["PATH"], "/usr/bin")
        }
    }

    func testListedRowsShowBeforeDone() async {
        let (center, streamer) = streamedCenter()
        center.startStreamedPlan(.workbench(2), workbenchID: 2)
        XCTAssertEqual(center.progress(for: .workbench(2))?.stage, .listing)
        await waitUntil("a run") { !streamer.runs.isEmpty }

        streamer.runs[0].send(CleanupStreamFixture.listed)
        await waitUntil("listed rows") { center.progress(for: .workbench(2))?.items.count == 3 }

        let progress = center.progress(for: .workbench(2))
        XCTAssertEqual(progress?.stage, .checking(done: 0, of: 2), "two worktrees to check")
        XCTAssertEqual(progress?.checking, [CleanupStreamFixture.wtA, CleanupStreamFixture.wtB, CleanupStreamFixture.branchA])
        XCTAssertEqual(center.cleanupPhase(for: .workbench(2)), .planning)
    }

    func testCheckedAndSizedFillIn() async {
        let (center, streamer) = streamedCenter()
        center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("a run") { !streamer.runs.isEmpty }
        let run = streamer.runs[0]
        run.send(CleanupStreamFixture.listed)
        run.send(CleanupStreamFixture.checked(CleanupStreamFixture.wtA))
        await waitUntil("wtA checked") { center.progress(for: .workbench(2))?.stage == .checking(done: 1, of: 2) }
        var progress = center.progress(for: .workbench(2))
        XCTAssertEqual(progress?.items.first { $0.key == CleanupStreamFixture.wtA }?.action, .remove)
        XCTAssertEqual(progress?.sizing, [CleanupStreamFixture.wtA], "a remove worktree waits for its size")
        XCTAssertEqual(progress?.stage, .checking(done: 1, of: 2))

        run.send(CleanupStreamFixture.checked(CleanupStreamFixture.wtB, action: "keep", reason: "uncommitted_changes"))
        run.send(CleanupStreamFixture.checked(CleanupStreamFixture.branchA, kind: "branch"))
        // A key `listed` never named (a stale LaunchServices entry) is a new row.
        run.send(CleanupStreamFixture.checked("lsreg:/tmp/example/acme/Old.app", kind: "lsreg"))
        await waitUntil("all checked") { center.progress(for: .workbench(2))?.items.count == 4 }
        XCTAssertEqual(center.progress(for: .workbench(2))?.checking, [])
        XCTAssertEqual(center.progress(for: .workbench(2))?.items.last?.key, "lsreg:/tmp/example/acme/Old.app")
        XCTAssertEqual(center.progress(for: .workbench(2))?.stage, .sizing(done: 0, of: 1))

        run.send(CleanupStreamFixture.sized(CleanupStreamFixture.wtA, bytes: 5_000))
        await waitUntil("sized") { center.progress(for: .workbench(2))?.sizing.isEmpty == true }
        progress = center.progress(for: .workbench(2))
        let sized = progress?.items.first { $0.key == CleanupStreamFixture.wtA }
        XCTAssertEqual(sized?.bytes, 5_000)
        XCTAssertEqual(sized?.bytesKnown, true)
        XCTAssertEqual(progress?.items.first { $0.key == CleanupStreamFixture.wtB }?.reason?.code, "uncommitted_changes")
    }

    func testDoneReplacesRows() async {
        let (center, streamer) = streamedCenter()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        center.now = { at }
        let task = center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("a run") { !streamer.runs.isEmpty }
        let run = streamer.runs[0]
        run.send(CleanupStreamFixture.listed)
        run.send(CleanupStreamFixture.donePlan)
        run.finish()
        await task.value

        let progress = center.progress(for: .workbench(2))
        XCTAssertEqual(progress?.items.map(\.key), [CleanupStreamFixture.wtA, CleanupStreamFixture.branchA])
        XCTAssertEqual(progress?.checking, [])
        XCTAssertEqual(progress?.sizing, [])
        XCTAssertEqual(progress?.stage, .ready(at: at))
        guard case let .ready(plan) = center.cleanupPhase(for: .workbench(2)) else {
            return XCTFail("the phase is the plan too, got \(center.cleanupPhase(for: .workbench(2)))")
        }
        XCTAssertEqual(plan.removableKeys, [CleanupStreamFixture.wtA])
    }

    func testStaleRunLinesAreDropped() async {
        let (center, streamer) = streamedCenter()
        let first = center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("run 1") { streamer.runs.count == 1 }
        let old = streamer.runs[0]
        old.send(CleanupStreamFixture.listed)
        await waitUntil("run 1 listed") { center.progress(for: .workbench(2))?.items.count == 3 }
        let firstID = center.progress(for: .workbench(2))?.runID

        center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("run 2") { streamer.runs.count == 2 }
        XCTAssertEqual(old.stopCount, 1, "Refresh stops the old process")
        let fresh = streamer.runs[1]
        fresh.send(CleanupStreamFixture.listed)
        await waitUntil("run 2 listed") {
            let progress = center.progress(for: .workbench(2))
            return progress?.runID != firstID && progress?.stage == .checking(done: 0, of: 2)
        }
        let before = center.progress(for: .workbench(2))

        old.send(CleanupStreamFixture.checked(CleanupStreamFixture.wtA))
        old.send(CleanupStreamFixture.donePlan)
        old.finish()
        await first.value
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(center.progress(for: .workbench(2)), before, "a late line of the stopped run changes nothing")
        XCTAssertEqual(center.cleanupPhase(for: .workbench(2)), .planning)
    }

    func testStreamWithoutDoneIsAFailedPlan() async {
        let (center, streamer) = streamedCenter()
        let task = center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("a run") { !streamer.runs.isEmpty }
        streamer.runs[0].send(CleanupStreamFixture.listed)
        streamer.runs[0].send("not json")
        streamer.runs[0].finish(status: 1, message: "watchtower exited with error: git crashed")
        await task.value

        let progress = center.progress(for: .workbench(2))
        XCTAssertEqual(progress?.stage, .failed("watchtower exited with error: git crashed"))
        XCTAssertEqual(progress?.items.count, 3, "the listed rows stay")
        XCTAssertEqual(center.cleanupPhase(for: .workbench(2)), .failed("watchtower exited with error: git crashed"))
    }

    func testPlanOverItsTimeLimitIsStoppedAndFails() async {
        let (center, streamer) = streamedCenter()
        let task = center.startStreamedPlan(.workbench(2), workbenchID: 2, timeLimit: .milliseconds(50))
        await waitUntil("a run") { !streamer.runs.isEmpty }
        await task.value

        XCTAssertEqual(streamer.runs[0].stopCount, 1)
        XCTAssertEqual(center.progress(for: .workbench(2))?.stage, .failed(SessionCleanupCenter.overLimitText(.milliseconds(50))))
    }

    func testOneApplyPerWorkbench() async {
        let (center, streamer) = streamedCenter()
        let session = center.startStreamedApply(.session(9), workbenchID: 2, items: [CleanupStreamFixture.wtA])
        XCTAssertTrue(center.isApplying(workbenchID: 2))
        XCTAssertFalse(center.isApplying(workbenchID: 3))

        let sweep = center.startStreamedApply(.workbench(2), workbenchID: 2, items: [CleanupStreamFixture.wtB])
        let refused = await sweep.value
        XCTAssertFalse(refused)
        await waitUntil("the session apply") { streamer.runs.count == 1 }
        XCTAssertEqual(streamer.runs.count, 1, "the second apply never launched")
        XCTAssertEqual(streamer.runs[0].args, [
            "workbench", "cleanup", "--session=9", "--workbench=2", "--apply",
            "--item=\(CleanupStreamFixture.wtA)", "--json", "--stream"
        ])

        center.startStreamedPlan(.session(9), workbenchID: 2)
        XCTAssertEqual(center.cleanupPhase(for: .session(9)), .applying, "a plan never cuts into an apply")
        XCTAssertEqual(streamer.runs.count, 1)

        streamer.runs[0].send(CleanupStreamFixture.doneApply())
        streamer.runs[0].finish()
        let ok = await session.value
        XCTAssertTrue(ok)
        XCTAssertFalse(center.isApplying(workbenchID: 2))
    }

    func testDeleteAndCleanUpApplyCountsAsApplying() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.applied)])
        runner.holdsCalls = true
        let center = SessionCleanupCenter(runner: runner, streamer: ScriptedCleanupStreamer())

        let applying = Task { await center.applyCleanup(sessionID: 9, workbenchID: 2, items: ["branch:feat/x"]) }
        while runner.heldCount == 0 { await Task.yield() }
        XCTAssertTrue(center.isApplying(workbenchID: 2))
        runner.release()
        _ = await applying.value
        XCTAssertFalse(center.isApplying(workbenchID: 2))
    }

    func testApplyEventsMoveRows() async {
        let (center, streamer) = streamedCenter()
        let plan = center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("plan run") { streamer.runs.count == 1 }
        streamer.runs[0].send(CleanupStreamFixture.listed)
        streamer.runs[0].send(CleanupStreamFixture.donePlanOf([
            (CleanupStreamFixture.wtA, "worktree"), (CleanupStreamFixture.wtB, "worktree"), (CleanupStreamFixture.branchA, "branch")
        ]))
        streamer.runs[0].finish()
        await plan.value

        let apply = center.startStreamedApply(.workbench(2), workbenchID: 2, items: [CleanupStreamFixture.wtA, CleanupStreamFixture.wtB])
        XCTAssertEqual(center.progress(for: .workbench(2))?.stage, .applying)
        await waitUntil("apply run") { streamer.runs.count == 2 }
        let run = streamer.runs[1]
        // The apply's own re-plan lines never reset the rows.
        run.send(CleanupStreamFixture.listed)
        run.send(CleanupStreamFixture.removing(CleanupStreamFixture.wtA))
        await waitUntil("removing") { center.progress(for: .workbench(2))?.removing == [CleanupStreamFixture.wtA] }
        XCTAssertEqual(center.progress(for: .workbench(2))?.items.count, 3)
        XCTAssertEqual(center.progress(for: .workbench(2))?.checking, [])

        run.send(CleanupStreamFixture.removed(CleanupStreamFixture.wtA, done: true))
        run.send(CleanupStreamFixture.removing(CleanupStreamFixture.wtB))
        run.send(CleanupStreamFixture.removed(CleanupStreamFixture.wtB, done: false, reason: "moved"))
        await waitUntil("removed") { center.progress(for: .workbench(2))?.items.count == 2 }
        var progress = center.progress(for: .workbench(2))
        XCTAssertEqual(progress?.removing, [])
        XCTAssertEqual(progress?.items.map(\.key), [CleanupStreamFixture.wtB, CleanupStreamFixture.branchA])
        XCTAssertEqual(progress?.items.first?.action, .keep)
        XCTAssertEqual(progress?.items.first?.reason?.code, "moved")

        run.send(CleanupStreamFixture.doneApply(
            #"{"key":"\#(CleanupStreamFixture.branchA)","kind":"branch","action":"keep","reason":"not_selected"}"#
        ))
        run.finish()
        let ok = await apply.value
        XCTAssertTrue(ok)
        progress = center.progress(for: .workbench(2))
        XCTAssertEqual(progress?.items.last?.action, .remove, "an unticked row is untouched by the result")
        guard case let .done(result) = progress?.stage else { return XCTFail("expected done, got \(String(describing: progress?.stage))") }
        XCTAssertEqual(result.summary, "ok")
        XCTAssertEqual(center.cleanupPhase(for: .workbench(2)), .done(result))
    }

    func testApplyWithoutDoneFails() async {
        let (center, streamer) = streamedCenter()
        let apply = center.startStreamedApply(.workbench(2), workbenchID: 2, items: [CleanupStreamFixture.wtA])
        await waitUntil("apply run") { !streamer.runs.isEmpty }
        streamer.runs[0].finish(status: 1, message: "boom")
        let ok = await apply.value
        XCTAssertFalse(ok)
        XCTAssertEqual(center.progress(for: .workbench(2))?.stage, .failed("boom"))
        XCTAssertEqual(center.failureText(for: .workbench(2)), "boom")
        XCTAssertFalse(center.isApplying(workbenchID: 2))
    }

    func testForgetDropsTheProgress() async {
        let (center, streamer) = streamedCenter()
        let task = center.startStreamedPlan(.workbench(2), workbenchID: 2)
        await waitUntil("a run") { !streamer.runs.isEmpty }
        center.forgetCleanup(.workbench(2))
        await task.value
        XCTAssertNil(center.progress(for: .workbench(2)))
        XCTAssertEqual(streamer.runs[0].stopCount, 1)
    }

    /// The production streamer: stdout as lines, the exit status, the
    /// CLI's stderr as today's failure text.
    func testProcessRunnerStreamsLinesAndExit() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/sh")
        let stream = try runner.streamCleanup(
            args: ["-c", "printf 'one\\ntwo'; echo bad >&2; exit 3"], environment: ["PATH": "/usr/bin:/bin"]
        )
        children.append(stream)
        var lines: [String] = []
        for await line in stream.lines { lines.append(line) }
        let exit = await stream.exit()

        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(exit.status, 3)
        XCTAssertEqual(exit.message, "watchtower exited with error: bad")
    }
}
