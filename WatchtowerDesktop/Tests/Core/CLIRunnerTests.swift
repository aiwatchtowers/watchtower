import Foundation
import Testing
@testable import WatchtowerCore
import WatchtowerTestSupport

@Suite("CLIRunner")
struct CLIRunnerTests {
    @Test("Captured process result preserves partial JSON on nonzero exit")
    func capturedPartialJSON() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/sh")
        let result = try await runner.capture(args: ["-c", "printf '{\"schema_version\":1}'; printf 'safe error' >&2; exit 3"],
                                              environment: ProcessInfo.processInfo.environment, timeout: 5)
        #expect(result.exitCode == 3)
        #expect(String(data: result.stdout, encoding: .utf8) == #"{"schema_version":1}"#)
        #expect(result.stderr == "safe error")
    }

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

    /// A stub CLI that leaves `marker` behind when it runs and prints the
    /// child's `WATCHTOWER_AI_ORIGIN`.
    private func originStub(in dir: URL, marker: URL) throws -> URL {
        let url = dir.appendingPathComponent("stub.sh")
        let body = "#!/bin/sh\ntouch \"\(marker.path)\"\nprintf '%s' \"${WATCHTOWER_AI_ORIGIN-unset}\"\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every generic entry refuses a model command before it builds a
    /// process, however the argv was put together (#1886 Task 18).
    @Test("generic entries refuse a model command and launch nothing")
    func testGenericRunRefusesModelCommand() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        let runner = ProcessCLIRunner(binaryPath: try originStub(in: dir, marker: marker).path)
        let env = ProcessInfo.processInfo.environment
        let base = ["--config", "/x"]
        let verb = String("generate".reversed().reversed()) // computed, not a literal
        let argvs = [["--config", "/x", "digest", "generate"], base + ["digest"] + [verb]]
        let calls: [([String]) async throws -> Void] = [
            { _ = try await runner.run(args: $0) },
            { _ = try await runner.run(args: $0, timeout: 5) },
            { _ = try await runner.run(args: $0, stdin: Data()) },
            { _ = try await runner.run(args: $0, environment: env) },
            { _ = try await runner.capture(args: $0, timeout: 5) },
            { _ = try await runner.capture(args: $0, environment: env, timeout: 5) }
        ]
        for argv in argvs {
            for call in calls {
                do {
                    try await call(argv)
                    Issue.record("expected modelCommandNeedsOrigin for \(argv)")
                } catch let CLIRunnerError.modelCommandNeedsOrigin(path) {
                    #expect(path == "digest generate")
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a refused call still launched the CLI")
        #expect(CLIRunnerError.modelCommandNeedsOrigin("digest generate").errorDescription?
            .contains("digest generate") == true)
    }

    @Test("runModel: background marks the child's environment, owner does not")
    func testRunModelBackgroundSetsEnv() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = ProcessCLIRunner(binaryPath: try originStub(in: dir, marker: dir.appendingPathComponent("ran")).path)
        let background = try await runner.runModel(
            args: ["digest", "generate"], origin: .background, timeout: nil, stdin: nil)
        #expect(String(bytes: background, encoding: .utf8) == "background")
        let owner = try await runner.runModel(args: ["digest", "generate"], origin: .owner, timeout: nil, stdin: nil)
        #expect(String(bytes: owner, encoding: .utf8) == "unset")
        // An inherited marker never reaches an owner launch.
        #expect(CLIOrigin.owner.environment(["WATCHTOWER_AI_ORIGIN": "background", "A": "1"]) == ["A": "1"])
        #expect(CLIOrigin.background.environment(["A": "1"]) == ["A": "1", "WATCHTOWER_AI_ORIGIN": "background"])
    }

    @Test("runModel feeds stdin like the generic entries")
    func runModelFeedsStdin() async throws {
        let runner = ProcessCLIRunner(binaryPath: "/bin/cat")
        let data = try await runner.runModel(args: [], origin: .owner, timeout: 30, stdin: Data("hello".utf8))
        #expect(String(bytes: data, encoding: .utf8) == "hello")
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
    /// owner-only gesture is confirmed without a window — while the child
    /// runs; the grant goes when it exits (F9).
    /// Both launch paths register: `run(args:)` and `run(args:stdin:)` (the
    /// Look step's `automations preview --stdin`, Inbox builder A).
    @Test("ProcessCLIRunner registers the child's argv and pid while it runs", arguments: [false, true])
    func processRunnerRegistersOwnerLaunch(withStdin: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid").path
        let releaseFile = directory.appendingPathComponent("release").path
        try #require(mkfifo(releaseFile, 0o600) == 0)
        // Each step waits for an event, never for a clock, and only shell
        // builtins run, so nothing outlives a cancelled runner. The child
        // records its pid, then writes 256 KiB to stdout — more than a pipe
        // holds — so it gets past that only once the runner drains stdout,
        // which starts after the runner registered the grant. Then it opens
        // the release FIFO (what the test's open waits for) and reads a line.
        let script = #"echo $$ > "$1"; i=0; while [ $i -lt 4096 ]; do printf '%064d' 0; i=$((i+1)); done; "#
            + #"read -r release < "$2" || :"#
        let args = ["-c", script, "sh", pidFile, releaseFile]
        let run = Task {
            let runner = ProcessCLIRunner(binaryPath: "/bin/sh")
            return withStdin ? try await runner.run(args: args, stdin: Data("RECIPE".utf8))
                             : try await runner.run(args: args)
        }
        // A run that ends before its child opens the FIFO (a launch failure)
        // must not leave the open below blocked: a reader of our own, held
        // open until the test is done, lets it return whenever it starts, and
        // the missing pid fails the test.
        let unblock = Task {
            _ = await run.result
            return open(releaseFile, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        func closeUnblockReader() async {
            let reader = await unblock.value
            if reader >= 0 { close(reader) }
        }
        var releaseFD = await ProcessPipes.offPool { open(releaseFile, O_WRONLY | O_CLOEXEC) }
        do {
            try #require(releaseFD >= 0, "the release FIFO did not open")
            _ = fcntl(releaseFD, F_SETNOSIGPIPE, 1)
            let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let child = try #require(pid, "the child did not run")
            #expect(OwnerConfirmGrants.shared.hasLive(pid: child))
            // A line, not only the writer's close: a FIFO reader on macOS can
            // miss the EOF of a writer that opens and closes at once, and then
            // waits forever (this test's hang under load).
            try #require(write(releaseFD, "go\n", 3) == 3)
            close(releaseFD)
            releaseFD = -1
            _ = try await run.value
            await closeUnblockReader()
            #expect(!OwnerConfirmGrants.shared.hasLive(pid: child))
            #expect(!OwnerConfirmGrants.shared.consume(args, pid: child))
        } catch {
            if releaseFD >= 0 { close(releaseFD) }
            run.cancel()
            _ = await run.result // ProcessCLIRunner terminates and waits before returning.
            await closeUnblockReader()
            throw error
        }
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
