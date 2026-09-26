import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class JiraBoardAnalysisCenterTests: XCTestCase {

    private func board(accountID: Int64 = 1, id: Int = 42) -> JiraBoard {
        JiraBoard(
            accountID: accountID,
            id: id,
            name: "Board \(id)",
            projectKey: "PROJ",
            boardType: "scrum",
            isSelected: true,
            issueCount: 0,
            syncedAt: "",
            rawColumnsJSON: "",
            rawConfigJSON: "",
            llmProfileJSON: "",
            workflowSummary: "",
            userOverridesJSON: "",
            configHash: "",
            profileGeneratedAt: ""
        )
    }

    func testAnalyzeInvokesAccountScopedForcedCLICall() async {
        let center = JiraBoardAnalysisCenter()
        let runner = FakeCLIRunner()
        center.start(board: board(accountID: 7, id: 42), runner: runner)
        await center.task(for: board(accountID: 7, id: 42))?.value

        XCTAssertEqual(runner.invocations, [[
            "jira", "--account", "7", "boards", "analyze", "--force", "42"
        ]])
    }

    func testSuccessClearsAnalyzingAndSignalsCompletion() async {
        let center = JiraBoardAnalysisCenter()
        let b = board()
        center.start(board: b, runner: FakeCLIRunner())
        await center.task(for: b)?.value

        XCTAssertFalse(center.isAnalyzing(b))
        XCTAssertNil(center.error(for: b))
        XCTAssertEqual(center.completedRuns, 1)
    }

    func testFailureSurvivesTheScreenGoingAway() async {
        // "начал → ушёл → вернулся": nothing holds the run but the Center, so a
        // failure that lands after the view is gone must still be readable when
        // the user comes back — the bug this Center exists to fix.
        let center = JiraBoardAnalysisCenter()
        let b = board()
        let runner = FakeCLIRunner(
            error: CLIRunnerError.nonZeroExit(code: 1, stderr: "LLM returned empty workflow")
        )
        center.start(board: b, runner: runner)
        await center.task(for: b)?.value

        XCTAssertFalse(center.isAnalyzing(b))
        XCTAssertEqual(center.error(for: b), "LLM returned empty workflow")
        // A failed run must not pose as a finished one.
        XCTAssertEqual(center.completedRuns, 0)
    }

    func testRunInFlightIsStillVisibleToALaterReader() async {
        let center = JiraBoardAnalysisCenter()
        let b = board()
        let runner = FakeCLIRunner()
        runner.blockUntilCancelled = true
        center.start(board: b, runner: runner)

        // The screen was destroyed and rebuilt here; the Center still knows.
        XCTAssertTrue(center.isAnalyzing(b))

        center.task(for: b)?.cancel()
        await center.task(for: b)?.value
    }

    func testSecondStartForTheSameBoardIsANoOp() async {
        let center = JiraBoardAnalysisCenter()
        let b = board()
        let runner = FakeCLIRunner()
        runner.blockUntilCancelled = true
        center.start(board: b, runner: runner)
        center.start(board: b, runner: runner)

        center.task(for: b)?.cancel()
        await center.task(for: b)?.value

        // Exactly one CLI call over the whole life of the two clicks.
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testBoardsAreTrackedPerSiteNotByRawID() async {
        // Raw board ids collide across connected sites (migration 00049).
        let center = JiraBoardAnalysisCenter()
        let first = board(accountID: 1, id: 42)
        let second = board(accountID: 2, id: 42)
        let blocking = FakeCLIRunner()
        blocking.blockUntilCancelled = true
        center.start(board: first, runner: blocking)

        XCTAssertTrue(center.isAnalyzing(first))
        XCTAssertFalse(center.isAnalyzing(second))

        center.task(for: first)?.cancel()
        await center.task(for: first)?.value
    }

    func testMissingCLIBinaryIsReportedAsAnError() async {
        let center = JiraBoardAnalysisCenter()
        let b = board()
        center.start(board: b, runner: nil)

        XCTAssertFalse(center.isAnalyzing(b))
        XCTAssertEqual(center.error(for: b), "Watchtower CLI not found")
    }

    func testStartingAgainClearsThePreviousError() async {
        let center = JiraBoardAnalysisCenter()
        let b = board()
        center.start(board: b, runner: FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")))
        await center.task(for: b)?.value
        XCTAssertNotNil(center.error(for: b))

        center.start(board: b, runner: FakeCLIRunner())
        await center.task(for: b)?.value
        XCTAssertNil(center.error(for: b))
    }
}
