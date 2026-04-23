import Foundation

// MARK: - CLIRunnerProtocol

/// Abstraction for shelling out to the watchtower CLI binary.
/// Conforming types run `watchtower <args>` and return stdout as Data.
/// Throws `CLIRunnerError` on non-zero exit or launch failure.
protocol CLIRunnerProtocol {
    /// Runs `watchtower <args>` and returns its stdout as Data.
    /// Throws on nonzero exit or launch failure.
    func run(args: [String]) async throws -> Data
}

// MARK: - CLIRunnerError

enum CLIRunnerError: LocalizedError {
    case binaryNotFound
    case launchFailed(underlying: Error)
    case nonZeroExit(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "watchtower binary not found. Make sure it is installed and in your PATH."
        case .launchFailed(let err):
            return "Failed to launch watchtower: \(err.localizedDescription)"
        case .nonZeroExit(let code, let stderr):
            let detail = stderr.isEmpty ? "exit \(code)" : stderr.prefix(300).description
            return "watchtower exited with error: \(detail)"
        }
    }
}

// MARK: - ProcessCLIRunner

/// Production implementation that launches the `watchtower` binary via `Process`.
struct ProcessCLIRunner: CLIRunnerProtocol {
    /// Absolute path to the watchtower binary.
    let binaryPath: String

    /// Creates a runner resolving the binary via `Constants.findCLIPath()`.
    /// Returns nil when the binary cannot be found.
    static func makeDefault() -> ProcessCLIRunner? {
        guard let path = Constants.findCLIPath() else { return nil }
        return ProcessCLIRunner(binaryPath: path)
    }

    func run(args: [String]) async throws -> Data {
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

        // Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds 64 KB.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
        }

        return stdoutData
    }
}
