import Foundation

/// `CompactionCLI` over the real `watchtower` binary.
package struct ProcessCompactionCLI: CompactionCLI {
    package enum Failure: Error, LocalizedError {
        case cliNotFound
        case timedOut
        case exited(Int32, stderr: String)

        package var errorDescription: String? {
            switch self {
            case .cliNotFound: "the watchtower CLI was not found"
            case .timedOut: "db compact --check timed out after 30 s"
            case let .exited(status, stderr): "db compact --check exited \(status): \(CLILog.detail(stderr))"
            }
        }
    }

    /// The `watchtower` binary; nil looks it up (`Constants.findCLIPath`) on
    /// every call. Tests pass a stub script.
    private let executablePath: String?

    package init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    /// Cancelling the calling task terminates the child (a quit during the
    /// check).
    package func check() async throws -> CompactionCheck {
        let process = try makeProcess(["db", "compact", "--check", "--json"])
        process.environment = await Constants.resolvedEnvironmentAsync()
        try Task.checkCancellation()
        let (output, timedOut) = await withTaskCancellationHandler {
            await ProcessPipes.run(process, timeout: .seconds(30))
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        if timedOut { throw Failure.timedOut }
        guard output.exitCode == 0 else { throw Failure.exited(output.exitCode, stderr: output.stderr) }
        return try decodeLastJSONLine(CompactionCheck.self, from: Data(output.stdout.utf8))
    }

    package func startCompact() throws -> any CompactionChild {
        let process = try makeProcess(["db", "compact", "--if-due", "--json"])
        // `check()` ran first and resolved the login-shell environment, so
        // this never blocks the caller on the shell probe.
        process.environment = Constants.resolvedEnvironmentIfReady()
        return try ProcessCompactionChild(process)
    }

    private func makeProcess(_ arguments: [String]) throws -> Process {
        guard let cliPath = executablePath ?? Constants.findCLIPath() else { throw Failure.cliNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        return process
    }
}

/// A launched `db compact --if-due` child; both streams drain from launch on
/// (SB3, see `ProcessPipes`).
private final class ProcessCompactionChild: CompactionChild, @unchecked Sendable {
    private let process: Process
    private let stdoutRead: Task<Data, Never>
    private let stderrRead: Task<Data, Never>

    /// Launches `process`; throws when it cannot start.
    init(_ process: Process) throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        self.process = process
        stdoutRead = ProcessPipes.drain(stdoutPipe)
        stderrRead = ProcessPipes.drain(stderrPipe)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    func waitForExit() async -> CompactionExit {
        let stdout = await stdoutRead.value
        let stderr = await stderrRead.value
        await ProcessPipes.offPool { [process] in process.waitUntilExit() }
        return CompactionExit(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }
}
