import Foundation

/// AI service that delegates to the bundled `watchtower ai query` CLI.
/// Replaces direct Claude/Codex subprocess invocations — the desktop app
/// no longer needs to know about AI provider binaries or their PATH.
package final class WatchtowerAIService: AIServiceProtocol, Sendable {

    package init() {}

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID, dbPath: dbPath,
               model: model, provider: provider, toolMode: toolMode, readFolder: nil)
    }

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let processHandle = WatchtowerProcessHandle()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                processHandle.terminate()
            }
            Task {
                do {
                    try await self.run(
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        sessionID: sessionID,
                        dbPath: dbPath,
                        model: model,
                        provider: provider,
                        toolMode: toolMode,
                        readFolder: readFolder,
                        processHandle: processHandle,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Run a quick connectivity check via `watchtower ai test`.
    /// Returns (ok, provider, model, error).
    package static func testConnection() async throws -> (ok: Bool, provider: String, model: String) {
        let cliPath = try findCLI()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.arguments = ["ai", "test"]

        let output = await ProcessPipes.run(process)
        if output.exitCode == -1 {
            throw WatchtowerAIError.launchFailed(output.stderr)
        }
        let data = Data(output.stdout.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A crash leaves no JSON: its stderr is the diagnostic.
            let detail = CLILog.detail(output.stderr)
            if output.exitCode != 0, !detail.isEmpty {
                throw WatchtowerAIError.exitCode(Int(output.exitCode), detail)
            }
            throw WatchtowerAIError.badResponse("Invalid JSON from watchtower ai test")
        }

        let ok = json["ok"] as? Bool ?? false
        let provider = json["provider"] as? String ?? "unknown"
        let model = json["model"] as? String ?? "unknown"

        if !ok {
            let errMsg = json["error"] as? String ?? "Unknown error"
            throw WatchtowerAIError.testFailed(errMsg, provider: provider, model: model)
        }

        if output.exitCode != 0 {
            throw WatchtowerAIError.exitCode(Int(output.exitCode), "watchtower ai test failed")
        }

        return (ok: true, provider: provider, model: model)
    }

    // MARK: - Private

    /// Build the `watchtower ai query` argument list. Pulled out of `run()` so
    /// the CLI-flag mapping (in particular `--provider`) can be unit tested
    /// without spawning a process.
    ///
    /// The prompt is always passed after an unconditional `--` separator, with
    /// every flag ahead of it — never only when the prompt happens to start
    /// with a dash. Without the separator, a prompt like "-v looks wrong" is
    /// parsed by cobra as flags, not as the positional argument. This mirrors
    /// the Go-side cobra test added alongside it (`cmd/ai_test.go`) — the two
    /// orderings (flags, `--`, prompt) must match.
    ///
    /// `readFolder` adds `--read-folder DIR` (a workbench folder the CLI
    /// resolves, or refuses with exit 2); it never comes with a tool mode —
    /// the CLI refuses the pair.
    package static func buildArgs(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String? = nil
    ) -> [String] {
        var args = ["ai", "query"]

        // The system prompt itself goes to stdin (see `run`): it carries the
        // chat's private context, which must not sit on argv (`ps`, ARG_MAX).
        if let systemPrompt, !systemPrompt.isEmpty {
            args += ["--system-prompt-stdin"]
        }
        if let sessionID, !sessionID.isEmpty {
            args += ["--session-id", sessionID]
        }
        if let dbPath, !dbPath.isEmpty {
            args += ["--db-path", dbPath]
        }
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        if let provider, !provider.isEmpty {
            args += ["--provider", provider]
        }
        if let toolMode {
            args += toolMode.cliArgs
        }
        if let readFolder, !readFolder.isEmpty {
            args += ["--read-folder", readFolder]
        }
        args += ["--", prompt]
        return args
    }

    /// The bytes `run` writes to the CLI's stdin: the system prompt that
    /// `buildArgs` announced with `--system-prompt-stdin`, or nil.
    package static func stdinPayload(systemPrompt: String?) -> Data? {
        guard let systemPrompt, !systemPrompt.isEmpty else { return nil }
        return Data(systemPrompt.utf8)
    }

    /// Writes `payload` to the CLI's stdin pipe and closes it. The write end
    /// ignores SIGPIPE, so a CLI that exits before reading (a cancelled chat,
    /// a refused flag, an early config error) makes the write fail with EPIPE
    /// instead of killing the app; that failure is dropped on purpose — the
    /// CLI's own exit status and stderr already report the run.
    package static func feedStdin(_ pipe: Pipe, payload: Data?) {
        let handle = pipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let payload {
            try? handle.write(contentsOf: payload)
        }
        try? handle.close()
    }

    // swiftlint:disable:next function_parameter_count
    private func run(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?,
        processHandle: WatchtowerProcessHandle,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let cliPath = try Self.findCLI()

        let args = Self.buildArgs(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: model,
            provider: provider,
            toolMode: toolMode,
            readFolder: readFolder
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdinPrompt = Self.stdinPayload(systemPrompt: systemPrompt)
        let stdin = Pipe()
        process.standardInput = stdin

        processHandle.set(process)
        try process.run()

        // On a thread of its own (never the caller's actor or the concurrency
        // pool, see ProcessPipes): a prompt larger than the pipe buffer blocks
        // until the CLI reads it, which it does first thing in RunE.
        Thread.detachNewThread { Self.feedStdin(stdin, payload: stdinPrompt) }

        let stderrRead = ProcessPipes.drain(stderr)

        var accumulatedText = ""
        let handle = stdout.fileHandleForReading

        for await line in handle.ndjsonLines {
            if Task.isCancelled { break }
            if let event = parseLine(line, accumulatedText: &accumulatedText) {
                continuation.yield(event)
            }
        }

        let exitStatus = await ProcessPipes.offPool { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }

        if !Task.isCancelled && exitStatus != 0 {
            let stderrText = String(data: (await stderrRead.value).prefix(65536), encoding: .utf8) ?? ""
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WatchtowerAIError.exitCode(
                Int(exitStatus),
                detail.isEmpty ? "watchtower ai query failed" : detail
            )
        }

        // Emit turnComplete with full accumulated text (matches old behavior)
        if !accumulatedText.isEmpty {
            continuation.yield(.turnComplete(accumulatedText))
        }

        continuation.yield(.done)
        continuation.finish()
    }

    /// Parse a JSON line from `watchtower ai query` output. Package-visible so
    /// the reset/accumulation contract can be unit-tested without a subprocess.
    package func parseLine(_ line: String, accumulatedText: inout String) -> StreamEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "text":
            if let text = json["text"] as? String {
                accumulatedText += text
                return .text(text)
            }
        case "reset":
            // A tool call interrupted the turn — drop the pre-tool preamble so
            // the final turnComplete carries only the post-tool answer.
            accumulatedText = ""
            return .reset
        case "session_id":
            if let sid = json["session_id"] as? String {
                return .sessionID(sid)
            }
        case "error":
            if let errMsg = json["error"] as? String {
                return .error(errMsg)
            }
        case "done":
            // Handled after the stream loop (turnComplete + done)
            break
        default:
            break
        }
        return nil
    }

    /// Find the watchtower CLI binary — bundled in .app or in PATH.
    private static func findCLI() throws -> String {
        if let path = Constants.findCLIPath() {
            return path
        }
        throw WatchtowerAIError.cliNotFound
    }
}

// MARK: - Process Handle

private final class WatchtowerProcessHandle: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        if let proc = process, proc.isRunning { proc.terminate() }
        lock.unlock()
    }
}

// MARK: - Errors

package enum WatchtowerAIError: LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case exitCode(Int, String)
    case badResponse(String)
    case testFailed(String, provider: String, model: String)

    package var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Watchtower CLI not found in app bundle"
        case let .launchFailed(detail):
            "Couldn't start the Watchtower CLI: \(detail)"
        case let .exitCode(code, detail):
            "AI query failed (exit \(code)): \(detail)"
        case let .badResponse(detail):
            "Bad AI response: \(detail)"
        case let .testFailed(error, provider, model):
            "AI test failed (\(provider)/\(model)): \(error)"
        }
    }
}
