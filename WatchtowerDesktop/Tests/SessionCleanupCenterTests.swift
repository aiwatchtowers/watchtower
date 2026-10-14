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
}
