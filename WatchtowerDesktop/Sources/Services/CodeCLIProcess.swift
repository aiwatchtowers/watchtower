import Darwin
import Foundation
import WatchtowerCore

/// One `watchtower code …` child (spec §3): spawned at utility QoS in a
/// process group of its own, its stdout streamed as raw chunks, its stderr
/// kept for the failure message, killed with its whole group (git children
/// included) and always reaped.
///
/// `posix_spawn` rather than `Process`: `Process` can neither start the
/// child in a new process group (so a kill would orphan its children) nor
/// be waited on without a run loop; the QoS is the same `.utility` class.
final class CodeCLIProcess: @unchecked Sendable {
    struct Exit: Equatable, Sendable {
        /// The exit status, or 128 + the signal for a killed child.
        let status: Int32
        let signaled: Bool
        let stderr: String

        var succeeded: Bool { !signaled && status == 0 }

        /// What the owner sees for a failed run: the CLI's own words when it
        /// said any (the end of its stderr), else the status.
        func failureMessage(command: String) -> String {
            let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { return String(said.suffix(500)) }
            return signaled
                ? "watchtower \(command) was killed (signal \(status - 128))."
                : "watchtower \(command) exited with status \(status)."
        }
    }

    enum LaunchError: Error, LocalizedError {
        case notFound
        case spawn(Int32)

        var errorDescription: String? {
            switch self {
            case .notFound: "The watchtower command-line tool was not found."
            case let .spawn(code): "Could not start the watchtower command-line tool (\(String(cString: strerror(code))))."
            }
        }
    }

    let pid: pid_t
    /// stdout as it arrives; finishes at EOF.
    let output: AsyncStream<Data>
    private let stdin: FileHandle
    /// Kept alive while its `readabilityHandler` feeds `output`.
    private let stdout: FileHandle
    private let exitTask: Task<Exit, Never>
    private let lock = NSLock()
    private var inputClosed = false
    private var terminated = false
    /// Reaped: the pid may belong to someone else from now on, so it is
    /// never signalled again.
    private let reaped: ReapedFlag

    /// stderr kept for the message: the last 8 KB.
    private static let stderrCap = 8192

    private init(pid: pid_t, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.pid = pid
        self.stdin = stdin
        self.stdout = stdout
        output = stdout.dataChunks
        let stderrRead = Task.detached { () -> Data in
            await ProcessPipes.offPool { stderr.readDataToEndOfFile() }
        }
        let reapedFlag = ReapedFlag()
        reaped = reapedFlag
        exitTask = Task.detached {
            let status = await ProcessPipes.offPool { Self.reap(pid, marking: reapedFlag) }
            let err = await stderrRead.value.suffix(Self.stderrCap)
            // Lossy on purpose: a message with a bad byte is still a message.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: err, as: UTF8.self)
            return Exit(status: Self.exitCode(status), signaled: Self.wasSignaled(status), stderr: text)
        }
    }

    deinit {
        // Never leave a running group behind (the owner dropped us without a kill).
        terminateGroup()
    }

    /// Spawns `executable arguments` with stdin, stdout and stderr on pipes.
    static func launch(executable: String, arguments: [String], environment: [String: String]) throws -> CodeCLIProcess {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw LaunchError.notFound }
        let pipes = (input: Pipe(), output: Pipe(), error: Pipe())
        var actions = try SpawnFileActions(
            stdin: pipes.input.fileHandleForReading.fileDescriptor,
            stdout: pipes.output.fileHandleForWriting.fileDescriptor,
            stderr: pipes.error.fileHandleForWriting.fileDescriptor
        )
        defer { actions.destroy() }
        var attributes = try SpawnAttributes()
        defer { attributes.destroy() }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions.raw, &attributes.raw, argv, envp)
        // The child holds its ends now; the parent's copies would keep EOF away.
        try? pipes.input.fileHandleForReading.close()
        try? pipes.output.fileHandleForWriting.close()
        try? pipes.error.fileHandleForWriting.close()
        guard rc == 0 else { throw LaunchError.spawn(rc) }
        let stdin = pipes.input.fileHandleForWriting
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        return CodeCLIProcess(
            pid: pid, stdin: stdin, stdout: pipes.output.fileHandleForReading, stderr: pipes.error.fileHandleForReading
        )
    }

    /// Writes `line` and a newline to the child's stdin, off the caller's
    /// thread (a child busy on a run does not read; the write must not block
    /// the main actor). A failed write is logged; the child's exit tells.
    func sendLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        let handle = stdin
        Thread.detachNewThread {
            do {
                try handle.write(contentsOf: data)
            } catch {
                NSLog("CodeCLIProcess: writing a request to the CLI failed: %@", String(describing: error))
            }
        }
    }

    /// EOF on stdin: a `--serve` child exits 0.
    func closeInput() {
        let shouldClose = lock.withLock {
            defer { inputClosed = true }
            return !inputClosed
        }
        if shouldClose { try? stdin.close() }
    }

    /// SIGTERM to the whole group, then SIGKILL to what is left of it after
    /// `grace`: a leader that ignored the TERM, or a child it forked while
    /// the TERM was on its way (that child never got it). Idempotent; a
    /// child that already exited on its own is not signalled at all.
    ///
    /// The late SIGKILL may come after the leader is reaped: a group id is
    /// not reused while the group has members, and pids do not wrap within
    /// a second, so it reaches the stragglers or no one.
    func terminateGroup(grace: Duration = .seconds(1)) {
        let first = lock.withLock {
            defer { terminated = true }
            return !terminated
        }
        closeInput()
        guard first, pid > 0, reaped.signalUnlessReaped(pid, SIGTERM) else { return }
        let pid = pid
        Task.detached {
            try? await Task.sleep(for: grace)
            _ = killpg(pid, SIGKILL)
        }
    }

    /// The child's exit, once reaped.
    var exitStatus: Exit {
        get async { await exitTask.value }
    }

    /// Decodes stdout as JSON lines off the main actor and hands each
    /// chunk's lines to `onLines`, then the exit and the count of lines that
    /// did not decode to `onExit` — both on the main actor, in order.
    @discardableResult
    func streamDecodedLines<Line: Decodable & Sendable>(
        as _: Line.Type,
        onLines: @escaping @MainActor @Sendable ([Line]) -> Void,
        onExit: @escaping @MainActor @Sendable (Exit, _ malformed: Int) -> Void
    ) -> Task<Void, Never> {
        let output = output
        return Task.detached { [self] in
            var decoder = CodeJSONLineDecoder<Line>()
            for await chunk in output {
                let lines = decoder.feed(chunk)
                if !lines.isEmpty { await onLines(lines) }
            }
            let tail = decoder.finish()
            if !tail.isEmpty { await onLines(tail) }
            if let bad = decoder.firstMalformed {
                NSLog("CodeCLIProcess: %ld undecodable line(s) from the CLI, first: %@", decoder.malformedCount, bad)
            }
            let exit = await exitStatus
            await onExit(exit, decoder.malformedCount)
        }
    }

    // MARK: Spawn plumbing

    /// Waits for the exit without reaping (the pid stays ours), marks it,
    /// then reaps.
    private static func reap(_ pid: pid_t, marking flag: ReapedFlag) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        flag.set()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        return status
    }

    private static func wasSignaled(_ status: Int32) -> Bool {
        let low = status & 0x7F
        return low != 0 && low != 0x7F
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        wasSignaled(status) ? 128 + (status & 0x7F) : (status >> 8) & 0xFF
    }
}

/// Set once the child is reaped. Signals go to the child's group only
/// before that, under the same lock, so a reused pid is never hit.
private final class ReapedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.withLock { isSet = true }
    }

    /// false (nothing sent) once the child is reaped.
    func signalUnlessReaped(_ pid: pid_t, _ signal: Int32) -> Bool {
        lock.withLock {
            guard !isSet else { return false }
            _ = killpg(pid, signal)
            return true
        }
    }
}

/// `posix_spawn_file_actions_t` mapping the three pipe ends onto 0, 1, 2.
private struct SpawnFileActions {
    var raw: posix_spawn_file_actions_t?

    init(stdin: Int32, stdout: Int32, stderr: Int32) throws {
        guard posix_spawn_file_actions_init(&raw) == 0 else { throw CodeCLIProcess.LaunchError.spawn(errno) }
        for (fd, target) in [(stdin, STDIN_FILENO), (stdout, STDOUT_FILENO), (stderr, STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&raw, fd, target)
        }
    }

    mutating func destroy() {
        posix_spawn_file_actions_destroy(&raw)
    }
}

/// A new process group, default signal dispositions, an empty mask, only
/// fds 0–2 inherited, and utility QoS (spec §3: lowered priority).
private struct SpawnAttributes {
    var raw: posix_spawnattr_t?

    init() throws {
        guard posix_spawnattr_init(&raw) == 0 else { throw CodeCLIProcess.LaunchError.spawn(errno) }
        posix_spawnattr_setflags(&raw, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&raw, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&raw, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&raw, &all)
        posix_spawnattr_set_qos_class_np(&raw, QOS_CLASS_UTILITY)
    }

    mutating func destroy() {
        posix_spawnattr_destroy(&raw)
    }
}

extension FileHandle {
    /// The handle's data as it arrives, through `readabilityHandler` (never
    /// `bytes`: see `ndjsonLines`), finishing at EOF.
    fileprivate var dataChunks: AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
        continuation.onTermination = { [weak self] _ in self?.readabilityHandler = nil }
        return stream
    }
}
