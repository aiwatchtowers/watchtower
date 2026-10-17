import Foundation
import Testing
@testable import WatchtowerCore

@Suite("CLIRunner")
struct CLIRunnerTests {
    @Test("CLIRunnerError binaryNotFound message")
    func errorBinaryNotFound() {
        let err = CLIRunnerError.binaryNotFound
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("watchtower binary not found"))
        #expect(desc.contains("PATH"))
    }

    @Test("CLIRunnerError launchFailed includes underlying message")
    func errorLaunchFailed() {
        struct MyErr: LocalizedError { var errorDescription: String? { "no exec bit" } }
        let err = CLIRunnerError.launchFailed(underlying: MyErr())
        #expect(err.errorDescription?.contains("Failed to launch") == true)
        #expect(err.errorDescription?.contains("no exec bit") == true)
    }

    @Test("CLIRunnerError nonZeroExit shows stderr when present")
    func errorNonZeroExitWithStderr() {
        let err = CLIRunnerError.nonZeroExit(code: 17, stderr: "boom: missing config")
        #expect(err.errorDescription?.contains("boom: missing config") == true)
    }

    @Test("CLIRunnerError nonZeroExit falls back to exit code when stderr empty")
    func errorNonZeroExitEmptyStderr() {
        let err = CLIRunnerError.nonZeroExit(code: 42, stderr: "")
        #expect(err.errorDescription?.contains("exit 42") == true)
    }

    @Test("CLIRunnerError nonZeroExit truncates very long stderr")
    func errorNonZeroExitTruncatesStderr() {
        let long = String(repeating: "x", count: 1000)
        let err = CLIRunnerError.nonZeroExit(code: 1, stderr: long)
        // The detail is constrained to a 300-char prefix.
        let desc = err.errorDescription ?? ""
        #expect(desc.count < 1000)
    }

    @Test("ProcessCLIRunner returns stdout for success")
    func processRunnerSuccess() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/echo")
        let data = try await runner.run(args: ["hello"])
        let out = String(data: data, encoding: .utf8) ?? ""
        #expect(out.contains("hello"))
    }

    /// AGENT-07 (board #568): the Desktop's own launch is the owner's, so its
    /// owner-only gesture is confirmed without a window.
    @Test("ProcessCLIRunner registers the child's argv as the owner's launch")
    func processRunnerRegistersOwnerLaunch() async throws {
        let args = ["owner-launch", UUID().uuidString]
        _ = try await ProcessCLIRunner(binaryPath: "/bin/echo").run(args: args)
        #expect(OwnerConfirmGrants.shared.consume(args))
        #expect(!OwnerConfirmGrants.shared.consume(args))
    }

    @Test("ProcessCLIRunner writes stdin to the child and closes it")
    func processRunnerStdin() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/cat")
        let data = try await runner.run(args: [], stdin: Data(#"{"columns":[],"hidden":[]}"#.utf8))
        #expect(data == Data(#"{"columns":[],"hidden":[]}"#.utf8))
    }

    @Test("ProcessCLIRunner surfaces non-zero exit")
    func processRunnerNonZero() async {
        let runner = ProcessCLIRunner(binaryPath: "/bin/sh")
        do {
            _ = try await runner.run(args: ["-c", "exit 9"])
            #expect(Bool(false), "expected throw")
        } catch let e as CLIRunnerError {
            if case .nonZeroExit(let code, _) = e {
                #expect(code == 9)
            } else {
                #expect(Bool(false), "expected nonZeroExit, got \(e)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type: \(error)")
        }
    }

    @Test("ProcessCLIRunner returns stderr in error message")
    func processRunnerStderr() async {
        let runner = ProcessCLIRunner(binaryPath: "/bin/sh")
        do {
            _ = try await runner.run(args: ["-c", "echo myerr 1>&2; exit 2"])
            #expect(Bool(false), "expected throw")
        } catch let e as CLIRunnerError {
            #expect(e.errorDescription?.contains("myerr") == true)
        } catch {
            #expect(Bool(false), "unexpected error type")
        }
    }

    @Test("ProcessCLIRunner surfaces launch failure for missing binary")
    func processRunnerLaunchFailed() async {
        let runner = ProcessCLIRunner(binaryPath: "/nonexistent/watchtower-fake")
        do {
            _ = try await runner.run(args: [])
            #expect(Bool(false), "expected throw")
        } catch let e as CLIRunnerError {
            if case .launchFailed = e {
                // ok
            } else {
                #expect(Bool(false), "expected launchFailed, got \(e)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type")
        }
    }

    /// SB3: `run` used to drain stdout to EOF, THEN stderr — a child that
    /// fills the stderr pipe (default macOS pipe buffer is 64 KiB) before
    /// closing stdout blocks forever on the write, and `run` never returns.
    /// Both pipes must be drained concurrently. Bounded by a race against a
    /// timeout task so a regression fails fast instead of hanging the suite.
    @Test("ProcessCLIRunner drains stdout and stderr concurrently, large stderr does not deadlock")
    func processRunnerLargeStderrDoesNotDeadlock() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/sh")
        // Well over the 64 KiB default pipe buffer.
        let script = "yes x | head -c 300000 1>&2; echo done"

        let data = try await withThrowingTaskGroup(of: Data?.self) { group -> Data? in
            group.addTask { try await runner.run(args: ["-c", script]) }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            // Whichever finishes first; the group cancels the other on scope exit.
            guard let first = try await group.next() else { return nil }
            return first
        }

        let out = try #require(data, "runner timed out — stdout/stderr pipes are deadlocking")
        #expect(String(data: out, encoding: .utf8)?.contains("done") == true)
    }

    // MARK: - CLILog
    //
    // The `print` itself is not observable from a test; what the line is allowed
    // to CONTAIN is, and that is the half with a rule behind it.

    @Test("CLILog.label keeps the subcommand path and flag names")
    func logLabelKeepsSubcommandAndFlags() {
        #expect(CLILog.label(["catchup", "run", "--json"]) == "catchup run --json")
        #expect(CLILog.label([]).isEmpty)
    }

    @Test("CLILog.label never logs argument values")
    func logLabelDropsArgumentValues() {
        let label = CLILog.label([
            "catchup", "feedback", "12",
            "--comment", "too much detail about the release, please shorten",
            "--transcript-file", "/tmp/rec_7.txt",
            "--model=claude-sonnet-4-6"
        ])
        // Free text and file paths carry the owner's own words; only the flag
        // names and the leading subcommand path may reach the log.
        #expect(label == "catchup feedback --comment --transcript-file --model")
        #expect(!label.contains("shorten"))
        #expect(!label.contains("/tmp/rec_7.txt"))
        #expect(!label.contains("claude-sonnet-4-6"))
    }

    @Test("CLILog.detail bounds a runaway child's stderr")
    func logDetailBoundsStderr() {
        let long = String(repeating: "x", count: 5000)
        let detail = CLILog.detail(long)
        #expect(detail.count == CLILog.stderrLimit + 1, "300 chars plus the elision marker")
        #expect(CLILog.detail("  boom  ") == "boom")
        #expect(CLILog.detail("\n\n").isEmpty, "a child that wrote only whitespace warned about nothing")
    }

    @Test("Fake CLIRunnerProtocol can stub runs")
    func fakeRunner() async throws {
        struct FakeRunner: CLIRunnerProtocol {
            let payload: Data
            func run(args: [String]) async throws -> Data {
                payload
            }
        }
        let r = FakeRunner(payload: Data("ok".utf8))
        let data = try await r.run(args: ["x"])
        #expect(String(data: data, encoding: .utf8) == "ok")
    }
}

@Suite("ProcessCLIRunner timeout")
struct ProcessCLIRunnerTimeoutTests {
    /// A stub that records its pid and then sleeps (exec keeps the pid).
    private func stub(in dir: URL, body: String) throws -> URL {
        let url = dir.appendingPathComponent("stub.sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("a child past its timeout is terminated and the call throws")
    func timesOutAndReapsTheChild() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid").path
        let runner = ProcessCLIRunner(binaryPath: try stub(in: dir, body: "echo $$ > \"$1\"\nexec /bin/sleep 5").path)
        var pid: pid_t = 0
        // The child is gone on every path: the runner waits for it before it throws.
        defer { if pid > 0 { kill(pid, SIGKILL) } }
        do {
            _ = try await runner.run(args: [pidFile], timeout: 1.5)
            Issue.record("expected a timeout")
        } catch let CLIRunnerError.nonZeroExit(code, stderr) {
            #expect(code == -1)
            #expect(stderr.hasPrefix("timed out after"))
        }
        pid = pid_t(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("a run that finishes inside its timeout returns its output")
    func finishesInsideTheTimeout() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/echo")
        let data = try await runner.run(args: ["done"], timeout: 30)
        #expect(String(bytes: data, encoding: .utf8) == "done\n")
    }
}
