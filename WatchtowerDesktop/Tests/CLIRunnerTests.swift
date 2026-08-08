import Foundation
import Testing
@testable import WatchtowerDesktop

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
            return try await group.next() ?? nil
        }

        let out = try #require(data, "runner timed out — stdout/stderr pipes are deadlocking")
        #expect(String(data: out, encoding: .utf8)?.contains("done") == true)
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
