import Foundation

// MARK: - ProcessOutput

/// A finished child process: its exit status plus both output streams decoded
/// as UTF-8, untrimmed. A launch failure is exit `-1` with the launch error's
/// description as `stderr` — the shape every ad-hoc wrapper already returned.
package struct ProcessOutput: Sendable {
    package let exitCode: Int32
    package let stdout: String
    package let stderr: String

    /// Both streams trimmed of surrounding whitespace, as the tuple the ad-hoc
    /// wrappers hand their callers.
    package var trimmed: (exitCode: Int32, stdout: String, stderr: String) {
        (
            exitCode,
            stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - ProcessPipes

/// The one place the ad-hoc `Process` wrappers drain a child's output.
///
/// SB3 (see `ProcessCLIRunner.run`): stdout and stderr MUST be drained
/// concurrently. A child that writes more than the 64 KiB pipe buffer to
/// stderr before it closes stdout blocks on that write until someone reads
/// stderr; a parent parked on stdout EOF — or on `waitUntilExit` — first
/// never gets there, and both sides wait forever.
package enum ProcessPipes {
    /// Starts reading `pipe` to EOF on a detached task. Call it right after
    /// `Process.run()` for any stream the caller does not read itself, and
    /// await the task's value once the stream it does read is done.
    package static func drain(_ pipe: Pipe) -> Task<Data, Never> {
        let handle = pipe.fileHandleForReading
        return Task.detached { handle.readDataToEndOfFile() }
    }

    /// Attaches fresh stdout/stderr pipes to a pre-configured `process`,
    /// launches it, drains both streams concurrently and waits for exit. The
    /// wait itself runs on a detached task, so no caller's actor is blocked.
    ///
    /// If `stdin` is given, `process.standardInput` must already be a `Pipe`:
    /// the string is written to it and the pipe closed (how secrets reach a
    /// child without touching argv). The write happens after both drains have
    /// started, so a child that answers before reading all of its input
    /// cannot wedge the write.
    package static func run(_ process: Process, stdin: String? = nil) async -> ProcessOutput {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessOutput(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutRead = drain(stdoutPipe)
        let stderrRead = drain(stderrPipe)

        if let stdin, let inputPipe = process.standardInput as? Pipe {
            if let data = stdin.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
        }

        let stdoutData = await stdoutRead.value
        let stderrData = await stderrRead.value
        await Task.detached { process.waitUntilExit() }.value

        return ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
