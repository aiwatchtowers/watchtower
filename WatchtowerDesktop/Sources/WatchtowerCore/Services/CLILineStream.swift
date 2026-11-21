import Darwin
import Foundation

// MARK: - CLILineStreaming

/// Runs `watchtower <args>` and hands its stdout over line by line as the
/// child writes it — the JSON-lines commands (`slack app create --json`,
/// `slack connect serve`) whose steps the Desktop shows while they run.
///
/// Every child runs in a process group of its own: cancelling the stream (or
/// `terminate()` on a session) kills the whole group and the child is reaped.
/// A secret goes over stdin, never argv.
package protocol CLILineStreaming: Sendable {
    /// One run: `stdin`, when given, is written and stdin closed (EOF either
    /// way). The stream yields each stdout line (framed on `\n` only) and
    /// finishes when the child exits — normally on exit 0, else throwing
    /// `CLIRunnerError.nonZeroExit` after every line it wrote. Cancelling the
    /// consuming task kills the child's process group.
    func lines(args: [String], stdin: Data?) -> AsyncThrowingStream<String, Error>
    /// A long-lived child the caller keeps talking to over stdin
    /// (`slack connect serve`).
    func session(args: [String]) -> any CLILineSession
    /// `lines(args:stdin:)` as a session, for a caller that must know when
    /// a run it cancelled has really ended (`waitForExit`): stdin written
    /// and closed as there, cancelling the consumer kills the group.
    func oneShot(args: [String], stdin: Data?) -> any CLILineSession
}

extension CLILineStreaming {
    package func oneShot(args: [String], stdin: Data?) -> any CLILineSession {
        let session = session(args: args)
        if let stdin { session.write(stdin) }
        session.closeInput()
        return session
    }
}

/// A running child: its stdout lines, its stdin, and its end.
package protocol CLILineSession: AnyObject, Sendable {
    /// Stdout lines; finishes as `CLILineStreaming.lines` does. Cancelling
    /// the consuming task terminates the child.
    var lines: AsyncThrowingStream<String, Error> { get }
    /// Writes `data` to the child's stdin (in call order; dropped once stdin
    /// is closed or the child is gone).
    func write(_ data: Data)
    /// Closes the child's stdin: the child reads EOF.
    func closeInput()
    /// Kills the child's whole process group (SIGKILL).
    func terminate()
    /// Returns once the child has exited and been reaped.
    func waitForExit() async
}

// MARK: - ProcessCLILineStream

/// The production `CLILineStreaming`: spawns `binaryPath` with
/// `posix_spawn` in a new process group (the `FileVaultStatus` pattern —
/// `Process` cannot give a child its own group).
package struct ProcessCLILineStream: CLILineStreaming {
    package let binaryPath: String
    private let environment: @Sendable () async -> [String: String]

    package init(
        binaryPath: String,
        environment: @escaping @Sendable () async -> [String: String] = { await Constants.resolvedEnvironmentAsync() }
    ) {
        self.binaryPath = binaryPath
        self.environment = environment
    }

    /// The installed `watchtower` binary; nil when it cannot be found.
    package static func makeDefault() -> Self? {
        guard let path = Constants.findCLIPath() else { return nil }
        return Self(binaryPath: path)
    }

    package func lines(args: [String], stdin: Data?) -> AsyncThrowingStream<String, Error> {
        let session = session(args: args)
        if let stdin { session.write(stdin) }
        session.closeInput()
        return session.lines
    }

    package func session(args: [String]) -> any CLILineSession {
        let session = ProcessCLILineSession(path: binaryPath, args: args)
        let environment = environment
        Task.detached(priority: .userInitiated) {
            let env = await environment()
            session.spawn(environment: env)
        }
        return session
    }
}

// MARK: - ProcessCLILineSession

/// One spawned child. Three threads of its own (never the Swift-concurrency
/// pool): stdout lines, stderr (kept for the error), and the exit waiter.
/// When the leader exits, whatever is left of its group is killed too, so a
/// straggler holding the pipes cannot keep the stream open.
final class ProcessCLILineSession: CLILineSession, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let path: String
    private let args: [String]
    /// Writes and the close run in order here; it starts once the child is
    /// spawned (or failed to), so nothing written before is lost.
    private let inputQueue = DispatchQueue(label: "watchtower.cli-line-session.stdin", attributes: .initiallyInactive)
    /// Set once before `inputQueue` is activated; then read and written only on it.
    private var stdinFD: Int32 = -1

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var reaped = false
    private var cancelled = false
    /// The stream finished: every line delivered and the child reaped.
    private var ended = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(path: String, args: [String]) {
        self.path = path
        self.args = args
        (lines, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.terminate() }
        }
    }

    func write(_ data: Data) {
        inputQueue.async { [self] in
            guard stdinFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard var base = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let written = Darwin.write(stdinFD, base, left)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return // EPIPE: the child is gone (no SIGPIPE: F_SETNOSIGPIPE).
                    }
                    left -= written
                    base += written
                }
            }
        }
    }

    func closeInput() {
        inputQueue.async { [self] in
            if stdinFD >= 0 { close(stdinFD) }
            stdinFD = -1
        }
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if pid > 0, !reaped { _ = killpg(pid, SIGKILL) }
    }

    func waitForExit() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.lock()
            if ended {
                lock.unlock()
                waiter.resume()
            } else {
                exitWaiters.append(waiter)
                lock.unlock()
            }
        }
    }

    // MARK: Spawn

    func spawn(environment: [String: String]) {
        let child: SpawnedChild
        do {
            child = try SpawnedChild.start(path: path, args: args, environment: environment)
        } catch {
            CLILog.failure(args: args, exitCode: -1, stderr: "\(error)")
            inputQueue.activate()
            finish(error: CLIRunnerError.launchFailed(underlying: error))
            return
        }
        // Set before the queue starts: writes queued earlier run after this.
        stdinFD = child.stdinFD
        inputQueue.activate()
        OwnerConfirmGrants.shared.register(args, pid: child.pid)
        lock.lock()
        pid = child.pid
        if cancelled { _ = killpg(child.pid, SIGKILL) }
        lock.unlock()
        run(child)
    }

    private func run(_ child: SpawnedChild) {
        let group = DispatchGroup()
        let stderr = StderrTail()
        let status = StatusBox()
        group.enter()
        Thread.detachNewThread { [self] in
            var splitter = NDJSONLineSplitter()
            Self.readAll(child.stdoutFD) { bytes in
                for line in splitter.append(bytes) { continuation.yield(line) }
            }
            if let tail = splitter.finish() { continuation.yield(tail) }
            close(child.stdoutFD)
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            Self.readAll(child.stderrFD) { stderr.append($0) }
            close(child.stderrFD)
            group.leave()
        }
        group.enter()
        Thread.detachNewThread { [self] in
            status.value = reap(child.pid)
            group.leave()
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            OwnerConfirmGrants.shared.revoke(pid: child.pid)
            closeInput()
            finish(status: status.value, stderr: stderr.text)
        }
    }

    /// Waits for the leader without reaping it (a zombie keeps its pid and
    /// group id from being recycled), kills what is left of its group, then
    /// reaps under the lock so `terminate()` never signals a recycled group.
    private func reap(_ pid: pid_t) -> Int32? {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 {
            if errno != EINTR { break }
        }
        lock.lock(); defer { lock.unlock() }
        _ = killpg(pid, SIGKILL)
        var status: Int32 = 0
        var result = waitpid(pid, &status, 0)
        while result < 0 && errno == EINTR { result = waitpid(pid, &status, 0) }
        reaped = true
        return result == pid ? status : nil
    }

    private func finish(status: Int32?, stderr: String) {
        let wasCancelled = resumeExitWaiters()
        if wasCancelled { continuation.finish(); return }
        // WIFEXITED: the low 7 bits are 0; the exit code is the next byte.
        let code: Int32 = status.map { $0 & 0x7f == 0 ? ($0 >> 8) & 0xff : -1 } ?? -1
        if code == 0 {
            CLILog.warning(args: args, stderr: stderr)
            continuation.finish()
        } else {
            CLILog.failure(args: args, exitCode: code, stderr: stderr)
            continuation.finish(throwing: CLIRunnerError.nonZeroExit(code: code, stderr: stderr))
        }
    }

    private func finish(error: Error) {
        _ = resumeExitWaiters()
        continuation.finish(throwing: error)
    }

    /// Marks the session ended, wakes `waitForExit()`; returns whether it was cancelled.
    private func resumeExitWaiters() -> Bool {
        lock.lock()
        reaped = true
        ended = true
        let waiters = exitWaiters
        exitWaiters = []
        let wasCancelled = cancelled
        lock.unlock()
        waiters.forEach { $0.resume() }
        return wasCancelled
    }

    private static func readAll(_ fd: Int32, _ chunk: (ArraySlice<UInt8>) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                chunk(buffer[0..<count])
            } else if count == 0 || errno != EINTR {
                return
            }
        }
    }
}

// MARK: - Spawn helpers

/// The child's pid and the parent's ends of its three pipes.
struct SpawnedChild {
    let pid: pid_t
    let stdinFD: Int32
    let stdoutFD: Int32
    let stderrFD: Int32

    struct SpawnError: Error, CustomStringConvertible {
        let code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    typealias PipeFactory = () throws -> (read: Int32, write: Int32)

    /// `makePipe` is a seam for tests (a pipe that fails part-way).
    static func start(
        path: String, args: [String], environment: [String: String], makePipe: PipeFactory = pipePair
    ) throws -> Self {
        // Every descriptor is closed on any failure until the spawn succeeds;
        // then the parent keeps its ends and closes the child's.
        var opened: [Int32] = []
        var spawnedChild = false
        defer { if !spawnedChild { opened.forEach { close($0) } } }
        func nextPipe() throws -> (read: Int32, write: Int32) {
            let pair = try makePipe()
            opened += [pair.read, pair.write]
            return pair
        }
        let input = try nextPipe(), output = try nextPipe(), errors = try nextPipe()

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input.read, 0)
        posix_spawn_file_actions_adddup2(&actions, output.write, 1)
        posix_spawn_file_actions_adddup2(&actions, errors.write, 2)
        posix_spawn_file_actions_addchdir_np(&actions, Constants.processWorkingDirectory().path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A group of its own; CLOEXEC_DEFAULT: no other descriptor of the app leaks in.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        guard spawned == 0 else { throw SpawnError(code: spawned) }
        spawnedChild = true
        [input.read, output.write, errors.write].forEach { close($0) }
        // A write after the child is gone fails with EPIPE instead of killing the app.
        _ = fcntl(input.write, F_SETNOSIGPIPE, 1)
        return Self(pid: pid, stdinFD: input.write, stdoutFD: output.read, stderrFD: errors.read)
    }

    static func pipePair() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnError(code: errno) }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }
}

/// The last bytes the child wrote to stderr (`CLILog.stderrLimit` bounds the
/// excerpt later; this only keeps the buffer from growing without end).
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private let limit = 16 * 1024

    func append(_ chunk: ArraySlice<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: chunk)
        if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The wait status, written by the waiter thread before the group's `leave`.
private final class StatusBox: @unchecked Sendable {
    var value: Int32?
}
