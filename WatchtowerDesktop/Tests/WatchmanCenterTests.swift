import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `watchman status` with the current fixture; holds `learn` and
/// `backtest` on a gate until the test releases them.
private final class ScriptedWatchmanRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var waiters: [(verb: String, continuation: CheckedContinuation<Void, Never>)] = []
    private var statusJSON: String
    private var statusError: Error?
    private var verbResult = CLICapturedResult(stdout: Data(#"{"ok":true}"#.utf8), exitCode: 0)
    private var currentGate = AsyncGate()

    /// The gate the next `learn`/`backtest` call waits on.
    var gate: AsyncGate { lock.withLock { currentGate } }
    func newGate() { lock.withLock { currentGate = AsyncGate() } }

    init(status: String) { statusJSON = status }

    var invocations: [[String]] { lock.withLock { calls } }
    func setStatus(_ json: String) { lock.withLock { statusJSON = json; statusError = nil } }
    func failStatus(_ error: Error) { lock.withLock { statusError = error } }
    func setVerbResult(_ result: CLICapturedResult) { lock.withLock { verbResult = result } }

    /// Returns once a call whose second argument is `verb` was made.
    func untilCalled(_ verb: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if calls.contains(where: { $0.dropFirst().first == verb }) { return true }
                waiters.append((verb, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func run(args: [String]) async throws -> Data {
        record(args)
        let (json, error) = lock.withLock { (statusJSON, statusError) }
        if let error { throw error }
        return Data(json.utf8)
    }

    func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
        record(args)
        await lock.withLock { currentGate }.wait()
        return lock.withLock { verbResult }
    }

    private func record(_ args: [String]) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            calls.append(args)
            let verb = args.dropFirst().first
            let ready = waiters.filter { $0.verb == verb }.map(\.continuation)
            waiters.removeAll { $0.verb == verb }
            return ready
        }
        ready.forEach { $0.resume() }
    }
}

@MainActor
final class WatchmanCenterTests: XCTestCase {
    private typealias Fixtures = WatchmanStatusFixtures

    func testLoadingToNotLearnedToLearningToNeverRunToResults() async throws {
        let runner = ScriptedWatchmanRunner(status: Fixtures.notLearned)
        let center = WatchmanCenter(runner: runner)
        XCTAssertEqual(center.state, .loading)

        await center.load()
        XCTAssertEqual(center.state, .notLearned(Fixtures.status(Fixtures.notLearned)))
        XCTAssertFalse(center.needsPolling)

        let learn = Task { await center.startLearning(workbench: 2) }
        await runner.untilCalled("learn")
        XCTAssertEqual(center.state, .learning(Fixtures.status(Fixtures.notLearned), workbench: 2))
        XCTAssertTrue(center.needsPolling)
        XCTAssertEqual(runner.invocations.last,
                       ["watchman", "learn", "--workbench", "2", "--start", "--json"])
        runner.setStatus(Fixtures.neverRun)
        runner.gate.release()
        await learn.value
        XCTAssertEqual(center.state, .neverRun(Fixtures.status(Fixtures.neverRun)))
        XCTAssertTrue(center.learningHere.isEmpty)

        runner.newGate()
        let run = Task { await center.runBacktest(workbench: 1) }
        await runner.untilCalled("backtest")
        XCTAssertEqual(center.state, .running(Fixtures.status(Fixtures.neverRun), progress: ""))
        XCTAssertEqual(runner.invocations.last, ["watchman", "backtest", "--workbench", "1", "--json"])
        runner.setStatus(Fixtures.results)
        runner.gate.release()
        await run.value
        XCTAssertEqual(center.state, .results(Fixtures.status(Fixtures.results)))
        XCTAssertNil(center.notices[1])
        XCTAssertFalse(center.needsPolling)
    }

    func testBacktestBusyShowsTheNotice() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.neverRun)
        runner.gate.release()
        runner.setVerbResult(CLICapturedResult(stdout: Data(#"{"ok":false,"error":"busy"}"#.utf8), exitCode: 1))
        let center = WatchmanCenter(runner: runner)
        await center.load()
        await center.runBacktest(workbench: 1)
        XCTAssertEqual(center.notices[1], WatchmanSettingsCopy.busy)
        XCTAssertEqual(center.state, .neverRun(Fixtures.status(Fixtures.neverRun)))
    }

    /// A run that started and failed is the status's `failed` row with its
    /// error: no second line under it.
    func testStartedBacktestFailureShowsOnlyTheFailedRow() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        runner.gate.release()
        runner.setVerbResult(CLICapturedResult(
            stdout: Data(#"{"ok":false,"workbench":1,"backtest_id":8,"status":"failed","verdict":"","cost_usd":0,"categories":[]}"#.utf8),
            exitCode: 1, stderr: "the AI provider hit your plan limit"))
        let center = WatchmanCenter(runner: runner)
        await center.load()
        runner.setStatus(Fixtures.failed)
        await center.runBacktest(workbench: 1)
        XCTAssertNil(center.notices[1])
        XCTAssertEqual(center.state, .failed(Fixtures.status(Fixtures.failed),
                                             message: "the AI provider hit your plan limit"))
    }

    /// A call that never got to a row (refused, binary missing) keeps its line.
    func testBacktestThatNeverStartedKeepsItsNotice() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.neverRun)
        runner.gate.release()
        runner.setVerbResult(CLICapturedResult(stdout: Data(), exitCode: 1, stderr: "refused under an agent\nmore"))
        let center = WatchmanCenter(runner: runner)
        await center.load()
        await center.runBacktest(workbench: 1)
        XCTAssertEqual(center.notices[1], "refused under an agent")
        XCTAssertEqual(center.state, .neverRun(Fixtures.status(Fixtures.neverRun)))
    }

    func testLearnFailureKeepsTheRowLearningWithItsLine() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.notLearned)
        runner.gate.release()
        runner.setVerbResult(CLICapturedResult(
            stdout: Data(#"{"ok":false,"workbench":2,"error":"label reply not JSON","watchman_on":true}"#.utf8),
            exitCode: 1))
        let center = WatchmanCenter(runner: runner)
        await center.load()
        runner.setStatus(Fixtures.learning)
        await center.startLearning(workbench: 2)
        XCTAssertEqual(center.notices[2], WatchmanSettingsCopy.learnFailed("label reply not JSON"))
        XCTAssertEqual(center.state, .learning(Fixtures.status(Fixtures.learning), workbench: 2))
    }

    func testCLIFailureIsReadFailedAndRetryRecovers() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        runner.failStatus(CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked\nmore"))
        let center = WatchmanCenter(runner: runner)
        await center.load()
        XCTAssertEqual(center.state, .readFailed("database is locked"))

        runner.setStatus(Fixtures.results)
        await center.load()
        XCTAssertEqual(center.state, .results(Fixtures.status(Fixtures.results)))
        XCTAssertNil(center.readError)
    }

    /// A reread that fails while polling keeps the status on screen.
    func testFailedRereadKeepsTheLastStatus() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.running)
        let center = WatchmanCenter(runner: runner)
        await center.load()
        runner.failStatus(CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        await center.load()
        XCTAssertEqual(center.state, .running(Fixtures.status(Fixtures.running),
                                              progress: "ux_text, 18 of 30 · 3 of 8 categories done"))
        XCTAssertEqual(center.readError, "database is locked")
        runner.setStatus(Fixtures.running)
        await center.load()
        XCTAssertNil(center.readError)
    }

    func testStatusPollsWhileABacktestRunsElsewhere() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.running)
        // The run finishes while the center waits between reads.
        let center = WatchmanCenter(runner: runner) { _ in runner.setStatus(Fixtures.results) }
        await center.watch()
        XCTAssertEqual(center.state, .results(Fixtures.status(Fixtures.results)))
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertTrue(runner.invocations.allSatisfy { $0 == ["watchman", "status", "--json"] })
    }
}
