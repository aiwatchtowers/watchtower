import Foundation

/// Whether FileVault encrypts this Mac's startup disk (#1769).
public enum FileVaultState: Equatable, Sendable {
    case on, off, unknown
}

/// Reads `fdesetup status` (no admin rights needed) under a time budget. A
/// failed, empty, unrecognised or too slow read is `.unknown`: the notice
/// shows only for a definite `.off`.
public struct FileVaultStatus: Sendable {
    public typealias Runner = @Sendable () async throws -> String
    /// Returns when the budget is spent; the read is then cancelled.
    public typealias Budget = @Sendable () async throws -> Void

    private let run: Runner
    private let budget: Budget

    /// `budget` is the injected clock: tests pass one that returns at once or never.
    public init(run: @escaping Runner, budget: @escaping Budget = Self.defaultBudget) {
        self.run = run
        self.budget = budget
    }

    /// The production reader: `/usr/bin/fdesetup status`.
    public static let live = Self(run: FileVaultProcess.output)

    public static let defaultBudget: Budget = { try await Task.sleep(for: .seconds(2)) }

    public func read() async -> FileVaultState {
        let run = run, budget = budget
        return await withTaskGroup(of: FileVaultState?.self) { group in
            group.addTask { Self.parse(try? await run()) }
            group.addTask {
                // A cancelled budget (the read finished first) is not a timeout.
                do { try await budget() } catch { return nil }
                return .unknown
            }
            var result = FileVaultState.unknown
            if let first = await group.next() {
                result = first ?? .unknown
                group.cancelAll()
            }
            return result
        }
    }

    static func parse(_ output: String?) -> FileVaultState {
        guard let text = output?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .unknown }
        if text.hasPrefix("FileVault is On") { return .on }
        if text.hasPrefix("FileVault is Off") { return .off }
        return .unknown
    }
}

/// `/usr/bin/fdesetup status` in its own process group: cancel kills the
/// group and reaps the child. A read error or a non-zero exit throws.
enum FileVaultProcess {
    static func output() async throws -> String {
        try await output(executable: "/usr/bin/fdesetup", arguments: ["status"])
    }

    static func output(executable: String, arguments: [String]) async throws -> String {
        let box = PidBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(with: Result { try runBlocking(box, executable, arguments) })
                }
            }
        } onCancel: {
            box.kill()
        }
    }

    /// The child's pid and whether it is reaped, under one lock: a cancel
    /// never signals a pid that has been reaped (and may be recycled).
    private final class PidBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var reaped = false
        private var cancelled = false

        func set(_ value: pid_t) {
            lock.lock(); defer { lock.unlock() }
            pid = value
            if cancelled { _ = killpg(value, SIGKILL) }
        }

        func kill() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if pid > 0, !reaped { _ = killpg(pid, SIGKILL) }
        }

        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        /// Kills the group (a failed read; the child may still run).
        func killNow() {
            lock.lock(); defer { lock.unlock() }
            if pid > 0, !reaped { _ = killpg(pid, SIGKILL) }
        }

        /// Waits for the child to exit WITHOUT reaping (it stays a zombie, so
        /// its pid cannot be recycled) and outside the lock, so a cancel
        /// still reaches killpg; then reaps under the lock.
        func reap() -> Int32? {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 {
                if errno != EINTR { break }
            }
            lock.lock(); defer { lock.unlock() }
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result < 0 && errno == EINTR { result = waitpid(pid, &status, 0) }
            reaped = true
            return result == pid ? status : nil
        }
    }

    private static func runBlocking(_ box: PidBox, _ path: String, _ arguments: [String]) throws -> String {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw CocoaError(.fileReadUnknown) }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attr, argv, [nil])
        close(writeFD)
        guard spawned == 0 else {
            close(readFD)
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(readFD) }
        box.set(pid)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var readFailed = false
        while true {
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count) } else if count == 0 { break } else if errno != EINTR {
                readFailed = true
                break
            }
        }
        if readFailed { box.killNow() }
        let status = box.reap()
        if box.wasCancelled { throw CancellationError() }
        // WIFEXITED with status 0: the raw wait status is 0.
        guard !readFailed, status == 0, let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadUnknown)
        }
        return text
    }
}
