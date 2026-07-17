import XCTest
@testable import WatchtowerDesktop

final class FakeTargetExtractNotifier: TargetExtractNotifying {
    private(set) var readyCalls: [Int] = []
    private(set) var failedCalls: [String] = []
    func sendTargetExtractReadyNotification(count: Int) { readyCalls.append(count) }
    func sendTargetExtractFailedNotification(reason: String) { failedCalls.append(reason) }
}

@MainActor
final class TargetExtractCenterTests: XCTestCase {

    private func oneTargetJSON() -> Data {
        Data("""
        {"extracted":[{"text":"Ship feature","intent":"","level":"day","custom_label":"",
        "period_start":"2026-07-09","period_end":"2026-07-09","priority":"medium",
        "parent_id":null,"ai_level_confidence":null,"secondary_links":[]}],
        "omitted_count":0,"notes":""}
        """.utf8)
    }

    func testSuccessGoesToReadyWithResult() async {
        let notifier = FakeTargetExtractNotifier()
        let center = TargetExtractCenter(notificationService: notifier)
        center.start(text: "ship feature", runner: FakeCLIRunner(stdout: oneTargetJSON()))
        await center.task?.value

        XCTAssertEqual(center.phase, .ready(count: 1))
        XCTAssertEqual(center.result?.extracted.count, 1)
        XCTAssertEqual(notifier.readyCalls, [1])
    }

    func testEmptyExtractionGoesToEmptyNotFailed() async {
        let notifier = FakeTargetExtractNotifier()
        let center = TargetExtractCenter(notificationService: notifier)
        let runner = FakeCLIRunner(stdout: Data(#"{"extracted":[],"omitted_count":0,"notes":""}"#.utf8))
        center.start(text: "nothing here", runner: runner)
        await center.task?.value

        XCTAssertEqual(center.phase, .empty)
        XCTAssertNil(center.result)
    }

    func testCLIErrorMapsToFriendlyFailed() async {
        let notifier = FakeTargetExtractNotifier()
        let center = TargetExtractCenter(notificationService: notifier)
        let stderr = "extraction failed: AI extraction call: claude CLI error: context deadline exceeded"
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
        center.start(text: "sample", runner: runner)
        await center.task?.value

        XCTAssertEqual(center.phase, .failed(message: "Extraction took too long. Try again.", canRetry: true))
        XCTAssertEqual(center.lastRawError?.contains("deadline exceeded"), true)
        XCTAssertEqual(notifier.failedCalls.count, 1)
    }

    func testResultSurvivesAfterStartReturns() async {
        // "начал → ушёл → вернулся": nothing holds the result but the Center.
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        center.start(text: "ship feature", runner: FakeCLIRunner(stdout: oneTargetJSON()))
        await center.task?.value
        // Simulate a consumer coming back later and reading the Center.
        XCTAssertEqual(center.phase, .ready(count: 1))
        XCTAssertEqual(center.result?.extracted.first?.text, "Ship feature")
    }

    func testCancelMidRunReturnsToIdle() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let runner = FakeCLIRunner()
        runner.blockUntilCancelled = true
        center.start(text: "long one", runner: runner)
        XCTAssertEqual(center.phase, .extracting)

        center.cancel()
        await center.task?.value

        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.result)
    }

    func testStartWhileExtractingIsANoOp() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let blocking = FakeCLIRunner()
        blocking.blockUntilCancelled = true
        center.start(text: "first", runner: blocking)
        XCTAssertEqual(center.phase, .extracting)

        let second = FakeCLIRunner(stdout: oneTargetJSON())
        center.start(text: "second", runner: second)
        XCTAssertEqual(second.invocations.count, 0, "a blocked start must not invoke the runner")

        center.cancel()
        await center.task?.value
    }

    func testRetryReRunsWithRememberedText() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let failing = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "network unreachable"))
        center.start(text: "remember me", runner: failing)
        await center.task?.value
        guard case .failed = center.phase else { return XCTFail("expected failed") }

        // retry() reuses the runner+text captured at start.
        center.retry()
        await center.task?.value
        XCTAssertEqual(failing.invocations.count, 2, "retry must re-invoke with the same runner")
    }

    func testDismissClearsTerminalState() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        center.start(text: "x", runner: FakeCLIRunner(stdout: oneTargetJSON()))
        await center.task?.value
        center.dismiss()
        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.result)
    }

    func testFriendlyMessageClaudeNotFound() {
        let r = TargetExtractCenter.friendlyMessage(for: "claude CLI not found — install Claude Code first")
        XCTAssertEqual(r.text, "Claude Code isn't installed. Install it and try again.")
        XCTAssertFalse(r.canRetry)
    }

    func testFriendlyMessageWatchtowerNotFound() {
        let r = TargetExtractCenter.friendlyMessage(for: "watchtower binary not found in PATH")
        XCTAssertEqual(r.text, "Watchtower CLI not found in PATH.")
        XCTAssertFalse(r.canRetry)
    }

    func testFriendlyMessageNetworkAndOverloadedAndDefault() {
        XCTAssertEqual(TargetExtractCenter.friendlyMessage(for: "connection reset by peer").text, "Network issue — check your connection and retry.")
        XCTAssertTrue(TargetExtractCenter.friendlyMessage(for: "connection reset by peer").canRetry)
        XCTAssertEqual(TargetExtractCenter.friendlyMessage(for: "API overloaded").text, "AI is busy right now. Try again in a moment.")
        XCTAssertEqual(TargetExtractCenter.friendlyMessage(for: "some unexpected explosion").text, "Couldn't extract targets. Try again.")
    }

    func testDismissWhileExtractingIsSafe() async {
        let center = TargetExtractCenter(notificationService: FakeTargetExtractNotifier())
        let runner = FakeCLIRunner()
        runner.blockUntilCancelled = true
        center.start(text: "long one", runner: runner)
        XCTAssertEqual(center.phase, .extracting)
        center.dismiss()
        await center.task?.value
        XCTAssertEqual(center.phase, .idle)
        XCTAssertNil(center.result)
    }
}
