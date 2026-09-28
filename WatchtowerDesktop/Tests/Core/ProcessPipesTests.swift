import Foundation
import Testing
@testable import WatchtowerCore

/// SB3 for the ad-hoc wrappers: every one of them used to read stdout to EOF
/// and only then stderr (or stderr only after `waitUntilExit`), so a child
/// writing more than the 64 KiB pipe buffer to stderr before closing stdout
/// hung both sides forever. They all drain through `ProcessPipes` now.
@Suite("ProcessPipes")
struct ProcessPipesTests {
    /// Well over the 64 KiB default pipe buffer, written to stderr BEFORE the
    /// child writes (and closes) stdout. Written by the shell's own `printf`
    /// builtin, so there is no child process at all: the watchdog's
    /// `terminate()` reaches only the shell, and a `yes | head` pipeline (or
    /// any external writer) would outlive it as an orphan.
    private static let largeStderrScript = "printf '%300000s' '' 1>&2; echo done"

    private static func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    /// Runs `body` against a deadline; on timeout the child is terminated so a
    /// regression fails the test instead of hanging the suite.
    private static func withDeadline<T: Sendable>(
        _ process: Process,
        seconds: UInt64 = 10,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled, process.isRunning { process.terminate() }
            return !Task.isCancelled
        }
        let value = await body()
        watchdog.cancel()
        let fired = await watchdog.value
        return fired ? nil : value
    }

    @Test("run drains a large stderr concurrently with stdout")
    func runLargeStderrDoesNotDeadlock() async throws {
        let process = Self.shell(Self.largeStderrScript)
        let output = await Self.withDeadline(process) { await ProcessPipes.run(process) }
        let result = try #require(output, "ProcessPipes.run deadlocked on >64 KiB of stderr")
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
        #expect(result.stderr.count >= 300_000)
    }

    @Test("drain lets a caller stream stdout while stderr fills")
    func drainWhileStreamingStdout() async throws {
        let process = Self.shell(Self.largeStderrScript)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let output = await Self.withDeadline(process) { () -> (lines: [String], stderr: Int) in
            let stderrRead = ProcessPipes.drain(stderrPipe)
            var lines: [String] = []
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines { lines.append(line) }
            } catch {}
            let stderrData = await stderrRead.value
            return (lines, stderrData.count)
        }
        let result = try #require(output, "streaming stdout deadlocked on >64 KiB of stderr")
        #expect(result.lines == ["done"])
        #expect(result.stderr >= 300_000)
        process.waitUntilExit()
    }

    /// The onboarding "Connect Slack" freeze: a main-actor-isolated CLI wrapper
    /// that waited synchronously blocked the main actor for the child's whole
    /// lifetime. Awaiting `run` from the main actor must leave it free — a
    /// main-actor ticker must get to run at least once while the child is
    /// still running. Counting only ticks inside that window (not a total
    /// against a threshold) keeps a slow CI runner from flaking it: a blocked
    /// main actor scores exactly zero there however fast the machine is.
    @MainActor
    @Test("run awaited from the main actor never blocks it")
    func runNeverBlocksTheMainActor() async {
        final class Window { var childRunning = true; var ticksWhileRunning = 0 }
        let window = Window()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                if window.childRunning { window.ticksWhileRunning += 1 }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let output = await ProcessPipes.run(Self.shell("sleep 1"))
        window.childRunning = false
        ticker.cancel()
        await ticker.value
        #expect(output.exitCode == 0)
        #expect(window.ticksWhileRunning >= 1, "main actor was blocked for the child's whole run")
    }

    @Test("run feeds stdin to the child and closes it")
    func runWritesStdin() async {
        let process = Self.shell("cat")
        process.standardInput = Pipe()
        let output = await Self.withDeadline(process) { await ProcessPipes.run(process, stdin: "secret-value") }
        #expect(output?.stdout == "secret-value")
        #expect(output?.exitCode == 0)
    }

    @Test("run reports a launch failure as exit -1 with the error text")
    func runLaunchFailure() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/watchtower-fake")
        let output = await ProcessPipes.run(process)
        #expect(output.exitCode == -1)
        #expect(!output.stderr.isEmpty)
        #expect(output.stdout.isEmpty)
    }

    @Test("trimmed strips surrounding whitespace from both streams")
    func trimmedStrips() async {
        let output = await ProcessPipes.run(Self.shell("echo ' out '; echo ' err ' 1>&2; exit 3"))
        let trimmed = output.trimmed
        #expect(trimmed.exitCode == 3)
        #expect(trimmed.stdout == "out")
        #expect(trimmed.stderr == "err")
    }
}
