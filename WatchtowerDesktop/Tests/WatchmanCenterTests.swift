import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `watchman status`, `profile` and `limits list` with the current
/// fixtures; holds `learn` and `backtest` on a gate until the test releases
/// them; answers the edit verbs (`profile set|unpin`, `limits add|remove`)
/// at once, keeping the `--text-file` contents as the CLI read them.
private final class ScriptedWatchmanRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var origins: [CLIOrigin] = []
    private var waiters: [(verb: String, continuation: CheckedContinuation<Void, Never>)] = []
    private var statusJSON: String
    private var statusError: Error?
    private var verbResult = CLICapturedResult(stdout: Data(#"{"ok":true}"#.utf8), exitCode: 0)
    private var currentGate = AsyncGate()
    private var profileJSON = WatchmanStatusFixtures.profile
    private var limitsJSON = WatchmanStatusFixtures.ownerLimits
    private var readErrors: [String: Error] = [:]
    private var editResult = CLICapturedResult(stdout: Data(), exitCode: 0)
    private var editError: Error?
    private var textFiles: [String] = []
    private var afterEdit: (@Sendable () -> Void)?
    private var heldReads: [String: AsyncGate] = [:]
    private var heldArrived: Set<String> = []
    private var heldWaiters: [(verb: String, continuation: CheckedContinuation<Void, Never>)] = []

    /// The gate the next `learn`/`backtest` call waits on.
    var gate: AsyncGate { lock.withLock { currentGate } }
    func newGate() { lock.withLock { currentGate = AsyncGate() } }

    init(status: String) { statusJSON = status }

    var invocations: [[String]] { lock.withLock { calls } }
    /// The origins `learn`/`backtest` named (model commands, `captureModel`).
    var modelOrigins: [CLIOrigin] { lock.withLock { origins } }
    func setStatus(_ json: String) { lock.withLock { statusJSON = json; statusError = nil } }
    func failStatus(_ error: Error) { lock.withLock { statusError = error } }
    func setVerbResult(_ result: CLICapturedResult) { lock.withLock { verbResult = result } }
    func setProfile(_ json: String) { lock.withLock { profileJSON = json } }
    func setLimits(_ json: String) { lock.withLock { limitsJSON = json } }
    /// Fails reads of `verb` (`profile`, `limits`) until set to nil.
    func failRead(_ verb: String, _ error: Error?) { lock.withLock { readErrors[verb] = error } }
    func setEditResult(_ result: CLICapturedResult) { lock.withLock { editResult = result } }
    func failEdit(_ error: Error) { lock.withLock { editError = error } }
    /// Runs after an edit verb, before it returns (the CLI's write).
    func onEdit(_ body: @escaping @Sendable () -> Void) { lock.withLock { afterEdit = body } }
    /// Holds the next read of `verb` after it took its reply, until the
    /// returned gate is released (a read overtaken by a newer one).
    func holdNextRead(_ verb: String) -> AsyncGate {
        let gate = AsyncGate()
        lock.withLock {
            heldReads[verb] = gate
            heldArrived.remove(verb)
        }
        return gate
    }
    /// Returns once the held read of `verb` has taken its reply and waits.
    func untilHeld(_ verb: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if heldArrived.contains(verb) { return true }
                heldWaiters.append((verb, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
    /// The `--text-file` contents each `profile set` read.
    var textFileContents: [String] { lock.withLock { textFiles } }
    /// The `--text-file` paths each `profile set` was given.
    var textFilePaths: [String] {
        invocations.compactMap { args in args.firstIndex(of: "--text-file").map { args[$0 + 1] } }
    }

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
        let verb = args.dropFirst().first ?? ""
        let (json, error) = lock.withLock { () -> (String, Error?) in
            switch verb {
            case "profile": (profileJSON, readErrors[verb])
            case "limits": (limitsJSON, readErrors[verb])
            default: (statusJSON, statusError)
            }
        }
        if let held = lock.withLock({ heldReads.removeValue(forKey: verb) }) {
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                heldArrived.insert(verb)
                let ready = heldWaiters.filter { $0.verb == verb }.map(\.continuation)
                heldWaiters.removeAll { $0.verb == verb }
                return ready
            }
            ready.forEach { $0.resume() }
            await held.wait()
        }
        if let error { throw error }
        return Data(json.utf8)
    }

    func captureModel(args: [String], origin: CLIOrigin, timeout: TimeInterval) async throws -> CLICapturedResult {
        lock.withLock { origins.append(origin) }
        return try await capture(args: args, timeout: timeout)
    }

    func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
        record(args)
        let verb = args.dropFirst().first
        guard verb == "profile" || verb == "limits" else {
            await lock.withLock { currentGate }.wait()
            return lock.withLock { verbResult }
        }
        if let index = args.firstIndex(of: "--text-file") {
            let text = (try? String(contentsOfFile: args[index + 1], encoding: .utf8)) ?? "<missing>"
            lock.withLock { textFiles.append(text) }
        }
        let (result, error, after) = lock.withLock { (editResult, editError, afterEdit) }
        after?()
        if let error { throw error }
        return result
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
        XCTAssertEqual(runner.modelOrigins, [.owner, .owner], "learn and backtest are the owner's model commands")
        XCTAssertEqual(center.state, .results(Fixtures.status(Fixtures.results)))
        XCTAssertNil(center.notices[1])
        XCTAssertFalse(center.needsPolling)
    }

    func testRelabellingNeverStartsABacktest() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.relabelling)
        runner.gate.release()
        let center = WatchmanCenter(runner: runner)
        await center.load()
        await center.runBacktest(workbench: 1)
        XCTAssertFalse(runner.invocations.contains { $0.dropFirst().first == "backtest" })
        XCTAssertTrue(center.backtestHere.isEmpty)
        // Once the pass is done the same call starts the run.
        runner.setStatus(Fixtures.results)
        await center.load()
        await center.runBacktest(workbench: 1)
        XCTAssertTrue(runner.invocations.contains { $0.dropFirst().first == "backtest" })
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
        // Two status reads; the profile and the limits are read once, after the first.
        let statusReads = runner.invocations.filter { $0 == ["watchman", "status", "--json"] }
        XCTAssertEqual(statusReads.count, 2)
        XCTAssertEqual(runner.invocations.count, 4)
    }

    func testPollsWhileRelabellingAndStopsWhenIdle() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.relabelling)
        let center = WatchmanCenter(runner: runner)
        await center.load()
        XCTAssertTrue(center.needsPolling)
        runner.setStatus(Fixtures.results)
        await center.load()
        XCTAssertFalse(center.needsPolling)
    }

    // MARK: - Editing (phase 2)

    private typealias Copy = WatchmanSettingsCopy

    /// A center that has read `results`, the profile and the limits.
    private func editingCenter(_ runner: ScriptedWatchmanRunner) async -> WatchmanCenter {
        let center = WatchmanCenter(runner: runner)
        await center.refresh()
        return center
    }

    func testRefreshReadsLimitsAndTheLearnedWorkbenchesProfiles() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        XCTAssertEqual(runner.invocations, [
            ["watchman", "status", "--json"],
            ["watchman", "profile", "--workbench", "1", "--json"],
            ["watchman", "limits", "list", "--json"]
        ])
        XCTAssertEqual(center.editing.profiles[1]?.categories.map(\.key), ["design", "ux_text"])
        XCTAssertEqual(center.editing.profiles[1]?.categories.first?.lines.count, 3)
        XCTAssertEqual(center.editing.limits?.owner.map(\.pattern), ["terraform apply", "create_jira_issue"])
    }

    /// A workbench Watchman has not learned has no profile to read.
    func testRefreshSkipsWorkbenchesNotLearned() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.notLearned)
        let center = await editingCenter(runner)
        XCTAssertFalse(runner.invocations.contains { $0.dropFirst().first == "profile" })
        XCTAssertTrue(center.editing.profiles.isEmpty)
        XCTAssertNotNil(center.editing.limits)
    }

    func testEditProfileWritesTempFileAndCallsSet() async throws {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        let saved = await center.saveProfile(workbench: 1, key: "design", text: "  Keep it simple.\n\nOne rule per line.  \n")
        XCTAssertTrue(saved)
        let set = try XCTUnwrap(runner.invocations.first { $0.starts(with: ["watchman", "profile", "set"]) })
        XCTAssertEqual(Array(set.prefix(8)),
                       ["watchman", "profile", "set", "--workbench", "1", "--key", "design", "--text-file"])
        XCTAssertEqual(runner.textFileContents, ["Keep it simple.\nOne rule per line."])
        let path = try XCTUnwrap(runner.textFilePaths.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the temporary file is removed after the call")
        // The profile is read again after the write.
        XCTAssertEqual(runner.invocations.last, ["watchman", "profile", "--workbench", "1", "--json"])
        XCTAssertNil(center.editing.errors[.profile(workbench: 1, key: "design")])
        XCTAssertTrue(center.editing.saving.isEmpty)
    }

    func testEditProfileRejectsAnEmptyOrTooLongTextBeforeTheCLI() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        let slot = WatchmanEditSlot.profile(workbench: 1, key: "design")
        let empty = await center.saveProfile(workbench: 1, key: "design", text: " \n  \n")
        XCTAssertFalse(empty)
        XCTAssertEqual(center.editing.errors[slot], Copy.profileEmptyText)
        let long = (1...21).map { "rule \($0)" }.joined(separator: "\n")
        let tooLong = await center.saveProfile(workbench: 1, key: "design", text: long)
        XCTAssertFalse(tooLong)
        XCTAssertEqual(center.editing.errors[slot], Copy.profileTooLong(lines: 21))
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["watchman", "profile", "set"]) })
    }

    func testUnpinCallsUnpin() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        await center.unpin(workbench: 1, key: "design")
        XCTAssertTrue(runner.invocations.contains(["watchman", "profile", "unpin", "--workbench", "1", "--key", "design"]))
        XCTAssertEqual(runner.invocations.last, ["watchman", "profile", "--workbench", "1", "--json"])
    }

    /// The sleep window shows in the status: unpinning it rereads that too.
    func testUnpinSleepWindowRereadsTheStatus() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        await center.unpin(workbench: 1, key: "sleep_window")
        XCTAssertEqual(runner.invocations.suffix(2), [
            ["watchman", "profile", "--workbench", "1", "--json"],
            ["watchman", "status", "--json"]
        ])
    }

    func testSleepWindowRejectsBadText() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        let slot = WatchmanEditSlot.profile(workbench: 1, key: "sleep_window")
        let badTexts = ["", "25:00-07:00", "00:30-7:45", "00:60-07:45", "00:30 to 07:45", "00:30-07:45-08:00",
                        "00 :30-07:45", "0 0:30-07:45", "٠٠:٣٠-٠٧:٤٥", "００:３０-０７:４５"]
        for bad in badTexts {
            let saved = await center.saveProfile(workbench: 1, key: "sleep_window", text: bad)
            XCTAssertFalse(saved, bad)
            XCTAssertEqual(center.editing.errors[slot], Copy.sleepBadFormat, bad)
        }
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["watchman", "profile", "set"]) })

        // The en dash the screen shows and blanks are fine; the CLI gets HH:MM-HH:MM.
        let saved = await center.saveProfile(workbench: 1, key: "sleep_window", text: " 23:15 – 06:30 \n")
        XCTAssertTrue(saved)
        let spaced = await center.saveProfile(workbench: 1, key: "sleep_window", text: "00:30 - 07:45")
        XCTAssertTrue(spaced)
        XCTAssertEqual(runner.textFileContents, ["23:15-06:30", "00:30-07:45"])
        XCTAssertNil(center.editing.errors[slot])
        XCTAssertEqual(runner.invocations.last, ["watchman", "status", "--json"])
    }

    func testAddLimitThenListReloads() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.onEdit {
            runner.setLimits(Fixtures.limits([
                (4, "command", "terraform apply"), (7, "tool", "create_jira_issue"), (9, "command", "kubectl delete")
            ]))
        }
        let added = await center.addLimit(kind: .command, pattern: "  kubectl delete ")
        XCTAssertTrue(added)
        XCTAssertEqual(runner.invocations.suffix(2), [
            ["watchman", "limits", "add", "--kind=command", "--pattern=kubectl delete"],
            ["watchman", "limits", "list", "--json"]
        ])
        XCTAssertEqual(center.editing.limits?.owner.last, WatchmanOwnerLimit(id: 9, kind: "command", pattern: "kubectl delete"))
        XCTAssertNil(center.editing.errors[.limits])
    }

    func testAddLimitChecksThePatternBeforeTheCLI() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        let cases: [(WatchmanLimitKind, String, String)] = [
            (.command, "   ", Copy.limitEmptyPattern),
            (.command, "terraform\napply", Copy.limitOneLine),
            (.tool, "create jira", Copy.limitToolBlanks)
        ]
        for (kind, pattern, line) in cases {
            let added = await center.addLimit(kind: kind, pattern: pattern)
            XCTAssertFalse(added)
            XCTAssertEqual(center.editing.errors[.limits], line)
        }
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["watchman", "limits", "add"]) })
    }

    func testRemoveLimitThenListReloads() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.onEdit { runner.setLimits(Fixtures.limits([(7, "tool", "create_jira_issue")])) }
        await center.removeLimit(id: 4)
        XCTAssertEqual(runner.invocations.suffix(2), [
            ["watchman", "limits", "remove", "--id", "4"],
            ["watchman", "limits", "list", "--json"]
        ])
        XCTAssertEqual(center.editing.limits?.owner.map(\.id), [7])
    }

    /// Built-in rows have no id: nothing on the screen can pass one to `limits remove`.
    func testBuiltinLimitHasNoRemove() async throws {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        let rows = try XCTUnwrap(center.editing.limits?.rows)
        XCTAssertEqual(rows.filter(\.isBuiltin).map(\.text), Fixtures.builtinLimits)
        XCTAssertTrue(rows.filter(\.isBuiltin).allSatisfy { $0.removableID == nil && $0.kind == nil })
        XCTAssertEqual(rows.filter { !$0.isBuiltin }.map(\.removableID), [4, 7])
        XCTAssertEqual(rows.filter { !$0.isBuiltin }.map(\.kind), [.command, .tool])
    }

    func testCLIErrorShownInline() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.setEditResult(CLICapturedResult(stdout: Data(), exitCode: 1,
                                               stderr: "the command pattern has an unclosed quote\nmore"))
        let added = await center.addLimit(kind: .command, pattern: "echo 'x")
        XCTAssertFalse(added)
        XCTAssertEqual(center.editing.errors[.limits], Copy.addFailed("the command pattern has an unclosed quote"))
        // The list is not reread after a refused write.
        XCTAssertEqual(runner.invocations.last?.prefix(3), ["watchman", "limits", "add"])

        await center.removeLimit(id: 4)
        XCTAssertEqual(center.editing.errors[.limits], Copy.removeFailed("the command pattern has an unclosed quote"))

        let profileSlot = WatchmanEditSlot.profile(workbench: 1, key: "design")
        runner.setEditResult(CLICapturedResult(stdout: Data(), exitCode: 1, stderr: "refused under an AI agent"))
        let saved = await center.saveProfile(workbench: 1, key: "design", text: "One rule.")
        XCTAssertFalse(saved)
        XCTAssertEqual(center.editing.errors[profileSlot], Copy.saveFailed("refused under an AI agent"))
        await center.unpin(workbench: 1, key: "design")
        XCTAssertEqual(center.editing.errors[profileSlot], Copy.unpinFailed("refused under an AI agent"))
        XCTAssertTrue(center.editing.saving.isEmpty)

        center.clearError(profileSlot)
        XCTAssertNil(center.editing.errors[profileSlot])
    }

    /// No watchtower binary: the edit says so in its line and keeps what was read.
    func testCLIMissingShownInline() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.failEdit(CLIRunnerError.binaryNotFound)
        let added = await center.addLimit(kind: .tool, pattern: "create_page")
        XCTAssertFalse(added)
        XCTAssertEqual(center.editing.errors[.limits],
                       Copy.addFailed(SessionReportCenter.errorLine(CLIRunnerError.binaryNotFound)))
        XCTAssertEqual(center.editing.limits?.owner.count, 2)
    }

    /// A read that fails keeps the last profile and limits and shows a line;
    /// the next read clears it.
    func testFailedEditingReadsShowTheirLines() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.failRead("limits", CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        runner.failRead("profile", CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        await center.refresh()
        XCTAssertEqual(center.editing.limitsReadError, "database is locked")
        XCTAssertEqual(center.editing.profileReadErrors[1], "database is locked")
        XCTAssertNotNil(center.editing.limits)
        XCTAssertNotNil(center.editing.profiles[1])

        runner.failRead("limits", nil)
        runner.failRead("profile", nil)
        await center.refresh()
        XCTAssertNil(center.editing.limitsReadError)
        XCTAssertNil(center.editing.profileReadErrors[1])
    }

    /// After a relaunch a new center has nothing in memory: it reads the
    /// pinned texts and the owner's limits back from the CLI.
    func testRelaunchReadsTheEditsBackFromTheCLI() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let first = await editingCenter(runner)
        runner.onEdit { runner.setLimits(Fixtures.limits([(4, "command", "terraform apply")])) }
        await first.removeLimit(id: 7)

        let relaunched = WatchmanCenter(runner: runner)
        XCTAssertNil(relaunched.editing.limits)
        await relaunched.watch()
        XCTAssertEqual(relaunched.editing.limits?.owner.map(\.id), [4])
        XCTAssertEqual(relaunched.editing.profiles[1]?.categories.first?.pinned, true)
    }

    /// The profile JSON's empty shape (a nil Go slice would be null).
    func testEmptyProfileAndNullSlicesDecode() throws {
        let empty = try JSONDecoder().decode(WatchmanProfile.self, from: Data(Fixtures.profileEmpty.utf8))
        XCTAssertTrue(empty.categories.isEmpty)
        let null = try JSONDecoder().decode(WatchmanLimits.self, from: Data(#"{"ok":true,"builtin":null,"owner":null}"#.utf8))
        XCTAssertEqual(null, WatchmanLimits(builtin: [], owner: []))
    }

    /// **Retry** after a failed status read also reads the profiles and the limits.
    func testRetryAfterAFailedReadAlsoReadsTheEdits() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        runner.failStatus(CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        runner.failRead("limits", CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        let center = WatchmanCenter(runner: runner)
        await center.refresh()
        XCTAssertEqual(center.state, .readFailed("database is locked"))
        XCTAssertTrue(center.editing.profiles.isEmpty)

        runner.setStatus(Fixtures.results)
        runner.failRead("limits", nil)
        await center.refresh()
        XCTAssertEqual(center.state, .results(Fixtures.status(Fixtures.results)))
        XCTAssertNotNil(center.editing.profiles[1])
        XCTAssertNotNil(center.editing.limits)
        XCTAssertNil(center.editing.limitsReadError)
    }

    /// A workbench that turns learned while the center polls has its profile
    /// read at once, and only once.
    func testProfileIsReadWhenAWorkbenchTurnsLearnedWhilePolling() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.learning)
        let center = WatchmanCenter(runner: runner)
        await center.refresh()
        XCTAssertNil(center.editing.profiles[1])
        runner.setStatus(Fixtures.running)
        await center.load()
        XCTAssertTrue(center.needsPolling)
        XCTAssertNotNil(center.editing.profiles[1])
        XCTAssertFalse(center.editing.isLoadingProfile(1))
        await center.load()
        let profileReads = runner.invocations.filter { $0.dropFirst().first == "profile" }
        XCTAssertEqual(profileReads.count, 1)
    }

    /// An older limits read that returns after a newer one changes nothing.
    func testStaleLimitsReadIsDropped() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        let gate = runner.holdNextRead("limits")
        defer { gate.release() }
        let stale = Task { await center.refresh() }
        // The refresh's limits read has taken its (old) reply and waits on the gate.
        await runner.untilHeld("limits")
        runner.onEdit { runner.setLimits(Fixtures.limits([(7, "tool", "create_jira_issue")])) }
        await center.removeLimit(id: 4)
        XCTAssertEqual(center.editing.limits?.owner.map(\.id), [7])
        gate.release()
        await stale.value
        XCTAssertEqual(center.editing.limits?.owner.map(\.id), [7])
    }

    func testProfileIsLoadingUntilItsFirstReadEnds() {
        var data = WatchmanEditingData()
        XCTAssertTrue(data.isLoadingProfile(1))
        data.profileReadErrors[1] = "database is locked"
        XCTAssertFalse(data.isLoadingProfile(1))
    }

    /// A cancelled profile read leaves the workbench unread: the next status
    /// read retries it instead of showing "Reading…" for good.
    func testCancelledProfileReadIsRetried() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.running)
        runner.failRead("profile", CancellationError())
        let center = WatchmanCenter(runner: runner)
        await center.refresh()
        XCTAssertTrue(center.editing.isLoadingProfile(1))
        XCTAssertNil(center.editing.profileReadErrors[1])

        runner.failRead("profile", nil)
        await center.load()
        XCTAssertNotNil(center.editing.profiles[1])
        XCTAssertFalse(center.editing.isLoadingProfile(1))
        await center.load()
        XCTAssertEqual(runner.invocations.filter { $0.dropFirst().first == "profile" }.count, 2)
    }

    /// Opening Settings again while the status read fails still rereads the
    /// profiles of the workbenches the last status showed learned.
    func testRefreshWithAFailedStatusReadStillReadsProfiles() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.failStatus(CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked"))
        runner.setProfile(Fixtures.profileEmpty)
        await center.refresh()
        XCTAssertEqual(center.readError, "database is locked")
        XCTAssertEqual(center.editing.profiles[1]?.categories, [])
    }

    /// A profile read a newer one overtook does not count as read: the
    /// next status read reads the profile again.
    func testSupersededProfileReadDoesNotMarkTheWorkbenchRead() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let gate = runner.holdNextRead("profile")
        defer { gate.release() }
        let center = WatchmanCenter(runner: runner)
        let first = Task { await center.refresh() }
        await runner.untilHeld("profile")
        // A save rereads the profile and publishes first.
        let saved = await center.saveProfile(workbench: 1, key: "design", text: "One rule.")
        XCTAssertTrue(saved)
        gate.release()
        await first.value
        let reads = { runner.invocations.filter { $0.dropFirst().first == "profile" && $0.count == 5 }.count }
        XCTAssertEqual(reads(), 2)
        await center.load()
        XCTAssertEqual(reads(), 3)
        await center.load()
        XCTAssertEqual(reads(), 3)
    }

    /// A profile read started before a `refresh()` does not mark the
    /// workbench read for the refresh: the refresh reads it again.
    func testProfileReadFromBeforeARefreshDoesNotCountForIt() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let profileGate = runner.holdNextRead("profile")
        defer { profileGate.release() }
        let center = WatchmanCenter(runner: runner)
        let first = Task { await center.load() }
        await runner.untilHeld("profile")
        let statusGate = runner.holdNextRead("status")
        defer { statusGate.release() }
        let second = Task { await center.refresh() }
        await runner.untilHeld("status")
        profileGate.release()
        await first.value
        statusGate.release()
        await second.value
        XCTAssertEqual(runner.invocations.filter { $0.dropFirst().first == "profile" }.count, 2)
    }

    /// A status reply with ok == false is a failed read: the profiles of the
    /// last status are still read.
    func testNotOKStatusReplyStillReadsProfiles() async {
        let runner = ScriptedWatchmanRunner(status: Fixtures.results)
        let center = await editingCenter(runner)
        runner.setStatus(#"{"ok": false, "error": "database is locked", "workbenches": []}"#)
        runner.setProfile(Fixtures.profileEmpty)
        await center.refresh()
        XCTAssertEqual(center.readError, "database is locked")
        XCTAssertEqual(center.editing.profiles[1]?.categories, [])
    }
}
