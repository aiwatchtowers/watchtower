import XCTest
@testable import WatchtowerCore

/// The argument contract of `watchtower inbox resolve`'s bulk forms and the
/// decoding of their last stdout line (cmd/inbox.go,
/// cmd/inbox_resolve_test.go), including the exit-1 error object.
final class InboxBulkCLITests: XCTestCase {
    /// Answers every `capture` with one result, keeping stdout on exit 1 as
    /// `ProcessCLIRunner` does.
    private final class CaptureRunner: CLIRunnerProtocol, @unchecked Sendable {
        let result: CLICapturedResult
        let error: Error?
        private(set) var calls: [[String]] = []
        private(set) var timeouts: [TimeInterval] = []

        init(stdout: String, exitCode: Int32 = 0, stderr: String = "", error: Error? = nil) {
            result = CLICapturedResult(stdout: Data(stdout.utf8), exitCode: exitCode, stderr: stderr)
            self.error = error
        }

        func run(args: [String]) async throws -> Data {
            XCTFail("bulk calls go through capture")
            return Data()
        }

        func capture(args: [String], timeout: TimeInterval) async throws -> CLICapturedResult {
            calls.append(args)
            timeouts.append(timeout)
            if let error { throw error }
            return result
        }
    }

    // MARK: - Arguments

    func testArgsPerOperation() async throws {
        XCTAssertEqual(InboxBulkCLI.args(.planSender("colleague-a@example.com")),
                       ["inbox", "resolve", "--dry-run", "--json", "--sender", "colleague-a@example.com",
                        "--trigger", "email_received"])
        XCTAssertEqual(InboxBulkCLI.args(.planOlderPeople(days: 7)),
                       ["inbox", "resolve", "--dry-run", "--json", "--older-than", "7d", "--people"])
        XCTAssertEqual(InboxBulkCLI.args(.planOlderPeople(days: 30)),
                       ["inbox", "resolve", "--dry-run", "--json", "--older-than", "30d", "--people"])
        XCTAssertEqual(InboxBulkCLI.args(.resolve(ids: ["4", "17", "9"])),
                       ["inbox", "resolve", "--ids", "4,17,9", "--json"])

        let runner = CaptureRunner(stdout: #"{"count":0,"ids":[]}"#)
        _ = try await InboxBulkCLI(runner: runner).planOlderPeople()
        XCTAssertEqual(runner.calls, [InboxBulkCLI.args(.planOlderPeople(days: 7))], "7 days by default")
        XCTAssertEqual(runner.timeouts, [120])
    }

    // MARK: - Dry run

    func testPlanDecodesCountAndIDs() async throws {
        let runner = CaptureRunner(stdout: "warning: something\n" + #"{"count":2,"ids":["12","5"]}"# + "\n")
        let plan = try await InboxBulkCLI(runner: runner).planSender("colleague-a@example.com")
        XCTAssertEqual(plan, InboxBulkPlan(ids: ["12", "5"], count: 2))
        XCTAssertEqual(runner.calls, [InboxBulkCLI.args(.planSender("colleague-a@example.com"))])
    }

    func testPlanRefusalThrowsTheCLIText() async {
        let refusal = "refusing to resolve inbox items in bulk under an AI agent (CLAUDECODE is set)"
        let runner = CaptureRunner(stdout: #"{"resolved":0,"of":0,"error":"\#(refusal)"}"#, exitCode: 1,
                                   stderr: "Error: \(refusal)")
        do {
            _ = try await InboxBulkCLI(runner: runner).planOlderPeople()
            XCTFail("a refusal is not a plan")
        } catch {
            XCTAssertEqual(error as? InboxBulkCLIError, .refused(refusal))
            XCTAssertEqual(error.localizedDescription, refusal)
        }

        // Exit 1 without the error object: the stderr's last line.
        let bare = CaptureRunner(stdout: "", exitCode: 1, stderr: "warning\nsome failure\n")
        do {
            _ = try await InboxBulkCLI(runner: bare).planSender("a@example.com")
            XCTFail("exit 1 is not a plan")
        } catch {
            XCTAssertEqual(error as? InboxBulkCLIError, .refused("some failure"))
        }
    }

    func testPlanCountMismatchIsUnexpected() async {
        for stdout in [#"{"count":3,"ids":["1","2"]}"#, #"{"count":1}"#, #"{"resolved":1,"skipped":0,"ids":["1"]}"#,
                       "not json", ""] {
            do {
                _ = try await InboxBulkCLI(runner: CaptureRunner(stdout: stdout)).planOlderPeople()
                XCTFail("\(stdout) is not a plan")
            } catch {
                XCTAssertEqual(error as? InboxBulkCLIError, .unexpectedAnswer, stdout)
                XCTAssertEqual(error.localizedDescription, "Unexpected answer from watchtower")
            }
        }
    }

    // MARK: - Resolve

    func testResolveDone() async {
        let runner = CaptureRunner(stdout: #"{"resolved":2,"skipped":1,"ids":["4","9"]}"#)
        let result = await InboxBulkCLI(runner: runner).resolve(ids: ["4", "9", "17"])
        XCTAssertEqual(result, .done(count: 2, skipped: 1))
        XCTAssertEqual(runner.calls, [["inbox", "resolve", "--ids", "4,9,17", "--json"]])
        XCTAssertEqual(runner.timeouts, [120])
    }

    func testResolvePartial() async {
        let runner = CaptureRunner(stdout: #"{"resolved":200,"of":250,"error":"chunk refused"}"#, exitCode: 1,
                                   stderr: "Error: closed 200 of 250: chunk refused")
        let result = await InboxBulkCLI(runner: runner).resolve(ids: (1...250).map(String.init))
        XCTAssertEqual(result, .partial(done: 200, of: 250, error: "chunk refused"))
    }

    func testResolveFailedWithNothingWritten() async {
        let runner = CaptureRunner(stdout: #"{"resolved":0,"of":3,"error":"database is locked"}"#, exitCode: 1)
        let result = await InboxBulkCLI(runner: runner).resolve(ids: ["1", "2", "3"])
        XCTAssertEqual(result, .failed("database is locked"))

        // Exit 0 is a write that ran: an unreadable answer says so and offers no Try Again.
        for stdout in ["", "oops", #"{"count":1,"ids":["1"]}"#, #"{"resolved":2,"skipped":0,"ids":["1"]}"#] {
            let odd = await InboxBulkCLI(runner: CaptureRunner(stdout: stdout)).resolve(ids: ["1"])
            XCTAssertEqual(odd, .unconfirmed("Watchtower closed the items but its answer could not be read."), stdout)
        }

        let bare = await InboxBulkCLI(runner: CaptureRunner(stdout: "", exitCode: 1, stderr: "Error: boom"))
            .resolve(ids: ["1"])
        XCTAssertEqual(bare, .failed("Error: boom"))
    }

    /// A timeout or a cancel after some chunks committed is not a plain
    /// failure: the line says some items may already be closed.
    func testResolveStoppedSaysSomeMayBeClosed() async {
        let timedOut = CaptureRunner(stdout: "", error: CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 122 s"))
        let result = await InboxBulkCLI(runner: timedOut).resolve(ids: (1...250).map(String.init))
        XCTAssertEqual(result, .failed(
            "Stopped before it finished; some items may already be closed. timed out after 122 s"))

        let cancelled = CaptureRunner(stdout: "", error: CancellationError())
        let stopped = await InboxBulkCLI(runner: cancelled).resolve(ids: ["1"])
        XCTAssertEqual(stopped, .failed(
            "Stopped before it finished; some items may already be closed. The press was cancelled."))

        // A dry run stopped wrote nothing: its reason as a refusal.
        do {
            _ = try await InboxBulkCLI(runner: timedOut).planOlderPeople()
            XCTFail("a timeout is not a plan")
        } catch {
            XCTAssertEqual(error as? InboxBulkCLIError, .refused("timed out after 122 s"))
        }
    }

    func testResolveTimeoutScalesWithTheIDs() async {
        XCTAssertEqual(InboxBulkCLI.timeout(ids: 3), 120)
        XCTAssertEqual(InboxBulkCLI.timeout(ids: 1_000), 130)
        XCTAssertEqual(InboxBulkCLI.timeout(ids: 1_000_000), 900, "capped")
        let runner = CaptureRunner(stdout: #"{"resolved":1000,"skipped":0,"ids":[]}"#)
        _ = await InboxBulkCLI(runner: runner).resolve(ids: (1...1_000).map(String.init))
        XCTAssertEqual(runner.timeouts, [130])
    }

    func testNoBinaryFails() async {
        let cli = InboxBulkCLI(runner: nil)
        do {
            _ = try await cli.planSender("a@example.com")
            XCTFail("no binary, no plan")
        } catch {
            XCTAssertEqual(error as? InboxBulkCLIError, .cliUnavailable)
        }
        let result = await cli.resolve(ids: ["1"])
        XCTAssertEqual(result, .failed("The watchtower CLI isn't available"))

        let notFound = CaptureRunner(stdout: "", error: CLIRunnerError.binaryNotFound)
        do {
            _ = try await InboxBulkCLI(runner: notFound).planOlderPeople()
            XCTFail("no binary, no plan")
        } catch {
            XCTAssertEqual(error as? InboxBulkCLIError, .cliUnavailable)
        }
        let notFoundResult = await InboxBulkCLI(runner: notFound).resolve(ids: ["1"])
        XCTAssertEqual(notFoundResult, .failed("The watchtower CLI isn't available"))
    }

    func testEmptyIDsRunsNothing() async {
        let runner = CaptureRunner(stdout: "")
        let result = await InboxBulkCLI(runner: runner).resolve(ids: [])
        XCTAssertEqual(result, .done(count: 0, skipped: 0))
        XCTAssertTrue(runner.calls.isEmpty)
    }
}
