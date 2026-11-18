import Foundation
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A `watchtower` stand-in for the consent answer: records argv, can fail
/// with a stderr, and can hold a call until released.
private final class ConsentRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var failure: String?
    private var holds = false
    private var gate: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var isStarted = false
    private var released = false

    var calls: [[String]] { lock.withLock { recorded } }

    func fail(with stderr: String?) { lock.withLock { failure = stderr } }
    func hold() { lock.withLock { holds = true } }

    func run(args: [String]) async throws -> Data {
        let (shouldHold, waiter) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            recorded.append(args)
            isStarted = true
            defer { startWaiter = nil }
            return (holds, startWaiter)
        }
        waiter?.resume()
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // A release() that came first must not be lost.
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }
        if let stderr = lock.withLock({ failure }) {
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: stderr)
        }
        return Data()
    }

    /// Returns once a call has started.
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if isStarted { return true }
                startWaiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }
}

@MainActor
final class BackgroundAIConsentModelTests: XCTestCase {
    private func makeModel(_ runner: ConsentRunner) -> BackgroundAIConsentModel {
        BackgroundAIConsentModel(
            runner: runner, configPath: "/tmp/acme/config.yaml",
            agent: .claude, reserve: nil, pollMinutes: 15, backfillDays: 30
        )
    }

    func testAllowCallsCLIWithYes() async {
        let runner = ConsentRunner()
        let ok = await makeModel(runner).allow()
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls, [["--config", "/tmp/acme/config.yaml", "ai", "background", "allow", "--yes"]])
    }

    func testNotNowCallsPause() async {
        let runner = ConsentRunner()
        let ok = await makeModel(runner).notNow()
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls, [["--config", "/tmp/acme/config.yaml", "ai", "background", "pause"]])
    }

    func testSavingDisablesThenClears() async {
        let runner = ConsentRunner()
        runner.hold()
        let model = makeModel(runner)
        XCTAssertFalse(model.isSaving)
        let answer = Task { await model.allow() }
        await runner.waitForStart()
        XCTAssertTrue(model.isSaving, "saving while the CLI call runs")
        runner.release()
        let ok = await answer.value
        XCTAssertTrue(ok)
        XCTAssertFalse(model.isSaving)
    }

    func testFailureShowsErrorAndReturnsFalse() async {
        let runner = ConsentRunner()
        runner.fail(with: "Error: disk full\n")
        let model = makeModel(runner)
        let ok = await model.notNow()
        XCTAssertFalse(ok)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.errorLine, BackgroundAIConsentCopy.saveFailed("disk full"))
    }

    /// Settings' pause writes the same verb, but its failure says background
    /// AI is still on rather than that nothing runs.
    func testPauseFailureSaysStillOn() async {
        let runner = ConsentRunner()
        let model = makeModel(runner)
        let ok = await model.pause()
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls, [["--config", "/tmp/acme/config.yaml", "ai", "background", "pause"]])
        runner.fail(with: "Error: disk full\n")
        let failed = await model.pause()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.errorLine, BackgroundAIConsentCopy.pauseFailed("disk full"))
    }

    func testFailureWithoutStderrNamesTheExit() async {
        let runner = ConsentRunner()
        runner.fail(with: "")
        let model = makeModel(runner)
        _ = await model.allow()
        XCTAssertEqual(model.errorLine, BackgroundAIConsentCopy.saveFailed("watchtower exited with code 1"))
    }

    func testSheetClosesOnlyAfterSuccess() async {
        let runner = ConsentRunner()
        runner.fail(with: "disk full")
        let model = makeModel(runner)
        let failed = await model.allow()
        XCTAssertFalse(failed, "a failed write keeps the sheet open")
        runner.fail(with: nil)
        let saved = await model.allow()
        XCTAssertTrue(saved)
        XCTAssertNil(model.errorLine, "a later success clears the error")
    }

    /// A re-entry while the sheet is up and saving keeps that sheet and its
    /// model: the answer is written once, never a second, conflicting time.
    func testReEntryDuringHeldSaveKeepsTheModelAndWritesOnce() async {
        let runner = ConsentRunner()
        runner.hold()
        var sheet = BackgroundAIConsentSheet()
        _ = sheet.present(configUnreadable: false) { self.makeModel(runner) }
        sheet.markMounted()
        guard let shown = sheet.model else { return XCTFail("opened") }
        let saving = Task { await shown.allow() }
        await runner.waitForStart()

        XCTAssertEqual(sheet.present(configUnreadable: false) { self.makeModel(runner) }, .alreadyVisible)
        XCTAssertTrue(sheet.model === shown)
        let second = await shown.notNow()
        XCTAssertFalse(second, "a second answer is refused while saving")
        runner.release()
        _ = await saving.value
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testFinishRunsWithButtonsOffAndRetriesOnlyTheFinish() async {
        let runner = ConsentRunner()
        let model = makeModel(runner)
        var busyDuringFinish = false
        await model.answer(.allow) {
            busyDuringFinish = model.isBusy
            return false
        }
        XCTAssertTrue(busyDuringFinish, "the buttons stay off until the finish returns")
        XCTAssertTrue(model.needsFinishRetry)
        XCTAssertFalse(model.isBusy)

        await model.answer(.notNow) { true }
        XCTAssertEqual(runner.calls.count, 1, "no new answer while the finish waits for a retry")

        await model.retryFinish { true }
        XCTAssertFalse(model.needsFinishRetry)
        XCTAssertEqual(runner.calls.count, 1, "a retry never writes the answer again")
    }

    func testFailedWriteSkipsTheFinish() async {
        let runner = ConsentRunner()
        runner.fail(with: "disk full")
        let model = makeModel(runner)
        var finished = false
        await model.answer(.allow) {
            finished = true
            return true
        }
        XCTAssertFalse(finished)
        XCTAssertFalse(model.needsFinishRetry)
        XCTAssertNotNil(model.errorLine)
    }

    func testSetupReadsThePersistedConfig() {
        let names = { (id: String) in id == "ollama" ? "Ollama / Local" : id }
        let peer = { (id: String) -> String? in id == "claude" ? "codex" : id == "codex" ? "claude" : nil }
        let catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        let plans = catalog.subscription
        let empty = BackgroundAIConsentSetup.read([:], displayName: names, subscription: plans, reservePeer: peer)
        XCTAssertEqual(empty, BackgroundAIConsentSetup(agent: .claude, reserve: nil, pollMinutes: 15, backfillDays: 30))

        let codex = BackgroundAIConsentSetup.read(
            ["ai": ["provider": "codex", "fallback": ["enabled": true]], "sync": ["poll_interval": "5m", "backfill_days": 7]],
            displayName: names, subscription: plans, reservePeer: peer
        )
        XCTAssertEqual(codex, BackgroundAIConsentSetup(agent: .codex, reserve: .claude, pollMinutes: 5, backfillDays: 7))

        let off = BackgroundAIConsentSetup.read(
            ["ai": ["provider": "ollama", "fallback": ["enabled": false, "provider": "codex"]]],
            displayName: names, subscription: plans, reservePeer: peer
        )
        XCTAssertEqual(off.agent, .other(name: "Ollama / Local"))
        XCTAssertNil(off.reserve, "no reserve line while the automatic reserve is off")
    }

    func testWhatRunsUsesTheConfiguredCadence() {
        let model = BackgroundAIConsentModel(
            runner: ConsentRunner(), configPath: "c", agent: .codex, reserve: .claude, pollMinutes: 5, backfillDays: 7
        )
        XCTAssertEqual(model.whatRuns, BackgroundAIConsentCopy.whatRuns(pollMinutes: 5, backfillDays: 7))
        XCTAssertEqual(model.planLines, [
            BackgroundAIConsentCopy.plan(.codex), BackgroundAIConsentCopy.reserve(from: .codex, to: .claude)
        ].compactMap { $0 })
        XCTAssertEqual(model.planLines.count, 2)
    }

    func testAgentFromProvider() {
        typealias Agent = BackgroundAIConsentCopy.Agent
        let catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        func agent(_ id: String) -> Agent {
            Agent(provider: id, displayName: catalog.displayName(id), subscription: catalog.subscription)
        }
        XCTAssertEqual(agent("claude").name, "Claude Code")
        XCTAssertEqual(agent("codex").name, "Codex")
        XCTAssertEqual(agent("claude"), .claude)
        XCTAssertEqual(agent("codex"), .codex)
        XCTAssertEqual(agent("ollama"), .other(name: "Ollama / Local"))
        XCTAssertEqual(agent("acme"), .other(name: "acme"), "an unknown id is named by itself")
        // Before the catalog is read: no subscription, the fallback name.
        let unread = AIModelCatalog(providers: [])
        XCTAssertEqual(
            Agent(provider: "claude", displayName: unread.displayName("claude"), subscription: unread.subscription),
            .other(name: "Claude")
        )
    }
}
