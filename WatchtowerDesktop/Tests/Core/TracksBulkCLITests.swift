import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `watchtower tracks dismiss` as the Inbox's bulk press sees it: the dry
/// run's plan and the `--ids` apply, with the pinned `--json` keys.
final class TracksBulkCLITests: XCTestCase {
    /// A runner that hands back stdout with a non-zero exit, which
    /// `FakeCLIRunner`'s default `capture` drops (the partial envelope).
    private struct CapturingRunner: CLIRunnerProtocol {
        let result: CLICapturedResult

        func run(args: [String]) async throws -> Data { result.stdout }

        func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult { result }
    }

    private func cli(_ stdout: String) -> (TracksBulkCLI, FakeCLIRunner) {
        let runner = FakeCLIRunner(stdout: Data(stdout.utf8))
        return (TracksBulkCLI(runner: runner), runner)
    }

    private func cli(exit code: Int32, stdout: String = "", stderr: String = "") -> TracksBulkCLI {
        TracksBulkCLI(runner: CapturingRunner(
            result: CLICapturedResult(stdout: Data(stdout.utf8), exitCode: code, stderr: stderr)))
    }

    private func failing(_ error: any Error) -> TracksBulkCLI {
        TracksBulkCLI(runner: FakeCLIRunner(error: error))
    }

    // MARK: - Arguments

    func testArgs() async throws {
        XCTAssertEqual(TracksBulkCLI.dryRunArgs(quietDays: 30),
                       ["tracks", "dismiss", "--quiet-days", "30", "--dry-run", "--json"])
        XCTAssertEqual(TracksBulkCLI.dismissArgs(ids: ["4", "9"]),
                       ["tracks", "dismiss", "--ids", "4,9", "--json"])

        let (planCLI, planRunner) = cli(#"{"count":0,"ids":[]}"#)
        _ = try await planCLI.planQuiet(days: 30)
        XCTAssertEqual(planRunner.invocations, [TracksBulkCLI.dryRunArgs(quietDays: 30)])

        let (dismissCLI, dismissRunner) = cli(#"{"dismissed":2,"skipped":0,"ids":[4,9]}"#)
        _ = await dismissCLI.dismiss(ids: ["4", "9"])
        XCTAssertEqual(dismissRunner.invocations, [TracksBulkCLI.dismissArgs(ids: ["4", "9"])])
    }

    // MARK: - Plan

    func testPlanDecodesIntegerIDsAsStrings() async throws {
        let (cli, _) = cli("warning: something\n" + #"{"count":2,"ids":[4,9]}"# + "\n\n")
        let plan = try await cli.planQuiet(days: 30)
        XCTAssertEqual(plan, InboxBulkPlan(ids: ["4", "9"], count: 2))
    }

    func testPlanNonZeroExitThrowsLastStderrLine() async {
        let cli = failing(CLIRunnerError.nonZeroExit(code: 1, stderr: "warning: old config\nnot allowed under an agent\n"))
        do {
            _ = try await cli.planQuiet(days: 30)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? TracksBulkCLIError, .refused("not allowed under an agent"))
            XCTAssertEqual(error.localizedDescription, "not allowed under an agent")
        }
    }

    func testPlanWithoutPinnedKeysIsUnexpected() async {
        for stdout in [#"{"count":2}"#, #"{"ids":[4]}"#, "done", "", #"{"count":1,"ids":["x"]}"#] {
            let (cli, _) = cli(stdout)
            do {
                _ = try await cli.planQuiet(days: 30)
                XCTFail("expected unexpectedAnswer for \(stdout)")
            } catch {
                XCTAssertEqual(error as? TracksBulkCLIError, .unexpectedAnswer, stdout)
                XCTAssertEqual(error.localizedDescription, "Unexpected answer from watchtower")
            }
        }
    }

    func testNoRunnerIsUnavailable() async {
        let cli = TracksBulkCLI(runner: nil)
        do {
            _ = try await cli.planQuiet(days: 30)
            XCTFail("expected cliUnavailable")
        } catch {
            XCTAssertEqual(error as? TracksBulkCLIError, .cliUnavailable)
            XCTAssertEqual(error.localizedDescription, "The watchtower CLI isn't available")
        }
        let result = await cli.dismiss(ids: ["4"])
        XCTAssertEqual(result, .failed("The watchtower CLI isn't available"))
    }

    func testPlanTimeoutThrowsRefusedWithTimeoutMessage() async {
        let cli = failing(CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 60 s"))
        do {
            _ = try await cli.planQuiet(days: 30)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? TracksBulkCLIError, .refused(TracksBulkCLI.timeoutMessage))
        }
    }

    // MARK: - Dismiss

    func testDismissDone() async {
        let (cli, _) = cli(#"{"dismissed":3,"skipped":1,"ids":[4,9,12]}"#)
        let result = await cli.dismiss(ids: ["4", "9", "12", "15"])
        XCTAssertEqual(result, .done(count: 3, skipped: 1))
    }

    func testDismissWithoutPinnedKeysIsFailed() async {
        let (cli, _) = cli(#"{"dismissed":3}"#)
        let result = await cli.dismiss(ids: ["4"])
        XCTAssertEqual(result, .failed("Unexpected answer from watchtower"))
    }

    func testDismissPartial() async {
        let cli = cli(exit: 1, stdout: #"{"dismissed":2,"of":5,"error":"disk full"}"# + "\n",
                      stderr: "disk full")
        let result = await cli.dismiss(ids: ["1", "2", "3", "4", "5"])
        XCTAssertEqual(result, .partial(done: 2, of: 5, error: "disk full"))
    }

    func testDismissNothingWrittenIsFailed() async {
        let cli = cli(exit: 1, stdout: #"{"dismissed":0,"of":5,"error":"disk full"}"#, stderr: "disk full")
        let result = await cli.dismiss(ids: ["1", "2", "3", "4", "5"])
        XCTAssertEqual(result, .failed("disk full"))
    }

    func testDismissRefusalIsFailedWithStderr() async {
        let cli = cli(exit: 1, stderr: "warning: old config\nrefused: owner-only command under an agent")
        let result = await cli.dismiss(ids: ["4"])
        XCTAssertEqual(result, .failed("refused: owner-only command under an agent"))

        let silent = self.cli(exit: 2)
        let silentResult = await silent.dismiss(ids: ["4"])
        XCTAssertEqual(silentResult, .failed("watchtower exited with code 2"))
    }

    func testDismissTimeoutIsUnknownOutcome() async {
        let cli = failing(CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 60 s"))
        let result = await cli.dismiss(ids: ["4"])
        XCTAssertEqual(result, .failed(TracksBulkCLI.timeoutMessage))
    }
}
