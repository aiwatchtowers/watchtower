import Foundation

// MARK: - CLIRunnerProtocol

/// Abstraction for shelling out to the watchtower CLI binary.
/// Conforming types run `watchtower <args>` and return stdout as Data.
/// Throws `CLIRunnerError` on non-zero exit or launch failure.
package protocol CLIRunnerProtocol {
    /// Runs `watchtower <args>` and returns its stdout as Data.
    /// Throws on nonzero exit or launch failure.
    func run(args: [String]) async throws -> Data
}

// MARK: - CLIRunnerError

package enum CLIRunnerError: LocalizedError {
    case binaryNotFound
    case launchFailed(underlying: Error)
    case nonZeroExit(code: Int32, stderr: String)

    package var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "watchtower binary not found. Make sure it is installed and in your PATH."
        case .launchFailed(let err):
            return "Failed to launch watchtower: \(err.localizedDescription)"
        case let .nonZeroExit(code, stderr):
            let detail = stderr.isEmpty ? "exit \(code)" : stderr.prefix(300).description
            return "watchtower exited with error: \(detail)"
        }
    }
}

// MARK: - CLILog

/// Log lines for a CLI invocation, shared by `ProcessCLIRunner` and by the
/// ad-hoc `Process` wrappers that predate it (`CatchUpViewModel`), so a CLI
/// failure leaves the same trace whichever wrapper ran it.
///
/// House logging style is a plain tagged `print` — this codebase has no OSLog
/// facility and this is not the place to introduce one.
package enum CLILog {
    /// Longest stderr excerpt a log line carries — the same bound
    /// `CLIRunnerError.errorDescription` already applies to the same text, so a
    /// runaway child cannot flood the log.
    package static let stderrLimit = 300

    /// A log-safe rendering of an invocation: the leading subcommand path (at
    /// most two tokens) plus flag NAMES, never flag values.
    ///
    /// Secrets are kept off argv by contract (QC-03,
    /// `docs/inventory/quick-connections.md`), but ordinary arguments still
    /// carry free text — a feedback comment, a regen correction, a file path —
    /// which has no business in a log file.
    package static func label(_ args: [String]) -> String {
        let subcommand = args.prefix { !$0.hasPrefix("-") }.prefix(2)
        // `--flag=value` carries its value in the same token: keep the name only.
        let flags = args.filter { $0.hasPrefix("-") }
            .map { String($0.split(separator: "=", maxSplits: 1)[0]) }
        return (Array(subcommand) + flags).joined(separator: " ")
    }

    /// The bounded stderr excerpt a log line carries.
    package static func detail(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= stderrLimit ? trimmed : String(trimmed.prefix(stderrLimit)) + "…"
    }

    /// Logs a CLI call that failed. The thrown error alone is not enough: every
    /// caller turns it into one line of UI text that the next reload replaces,
    /// so a crash leaves no trace to diagnose afterwards.
    package static func failure(args: [String], exitCode: Int32, stderr: String) {
        print("[CLI] \(label(args)) failed (exit \(exitCode)): \(detail(stderr))")
    }

    /// Logs a call that SUCCEEDED while writing to stderr — the degradation
    /// warnings of the exit-0 envelope family (`recap_ok`, `segments_ok`,
    /// `connections add`'s non-claude-provider notice). Dropping those on the
    /// floor is the gap the Swift conventions already name
    /// (`docs/review/review-rules.md`, "Go ↔ Swift dual-path contracts").
    /// Silent when the child wrote nothing.
    package static func warning(args: [String], stderr: String) {
        let text = detail(stderr)
        guard !text.isEmpty else { return }
        print("[CLI] \(label(args)) exited 0 with stderr: \(text)")
    }
}

// MARK: - ProcessCLIRunner

/// Production implementation that launches the `watchtower` binary via `Process`.
package struct ProcessCLIRunner: CLIRunnerProtocol {
    /// Absolute path to the watchtower binary.
    package let binaryPath: String

    package init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Creates a runner resolving the binary via `Constants.findCLIPath()`.
    /// Returns nil when the binary cannot be found.
    package static func makeDefault() -> ProcessCLIRunner? {
        guard let path = Constants.findCLIPath() else { return nil }
        return ProcessCLIRunner(binaryPath: path)
    }

    package func run(args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            // The binary store mid-replace, or a copy that lost its exec bit:
            // ~30 call sites turn this into one line of UI and nothing else.
            CLILog.failure(args: args, exitCode: -1, stderr: error.localizedDescription)
            throw CLIRunnerError.launchFailed(underlying: error)
        }

        // Terminate the subprocess if the awaiting Task is cancelled (the user
        // pressed Cancel in the extraction capsule). `readDataToEndOfFile` /
        // `waitUntilExit` run on detached tasks (never the main actor);
        // terminate() from the cancel handler unblocks both reads.
        //
        // SB3: stdout and stderr MUST be drained concurrently, not
        // sequentially. A child that fills the stderr pipe (macOS's default
        // pipe buffer is 64 KiB) before it finishes writing stdout blocks on
        // the write syscall until something reads stderr — if we're still
        // parked in `readDataToEndOfFile()` on stdout at that point, both
        // sides wait forever.
        return try await withTaskCancellationHandler {
            async let stdoutRead = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderrRead = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value
            let stdoutData = await stdoutRead
            let stderrData = await stderrRead
            process.waitUntilExit()

            if Task.isCancelled {
                throw CancellationError()
            }
            let exitCode = process.terminationStatus
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if exitCode != 0 {
                CLILog.failure(args: args, exitCode: exitCode, stderr: stderr)
                throw CLIRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }
            // Exit 0 with stderr is a warning the child wanted heard; without
            // this it was read off the pipe and dropped on the floor.
            CLILog.warning(args: args, stderr: stderr)
            return stdoutData
        } onCancel: {
            process.terminate()
        }
    }
}
