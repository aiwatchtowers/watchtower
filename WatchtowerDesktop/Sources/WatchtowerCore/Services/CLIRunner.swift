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
            if exitCode != 0 {
                let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw CLIRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }
            return stdoutData
        } onCancel: {
            process.terminate()
        }
    }
}
