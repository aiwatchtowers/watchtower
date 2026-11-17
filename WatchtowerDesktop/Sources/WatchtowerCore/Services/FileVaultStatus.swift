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
/// group and reaps the child.
enum FileVaultProcess {
    static func output() async throws -> String {
        let box = PidBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(with: Result { try runBlocking(box) })
                }
            }
        } onCancel: {
            box.kill()
        }
    }

    private final class PidBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var cancelled = false

        /// False when already cancelled: the caller must not start.
        func set(_ value: pid_t) -> Bool {
            lock.lock(); defer { lock.unlock() }
            pid = value
            if cancelled { _ = killpg(value, SIGKILL) }
            return !cancelled
        }

        func kill() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if pid > 0 { _ = killpg(pid, SIGKILL) }
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            pid = 0
        }
    }

    private static func runBlocking(_ box: PidBox) throws -> String {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw CocoaError(.fileReadUnknown) }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        let path = "/usr/bin/fdesetup"
        let argv = [strdup(path), strdup("status"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attr, argv, [nil])
        close(writeFD)
        guard spawned == 0 else {
            close(readFD)
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(readFD) }
        _ = box.set(pid)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count) } else if count == 0 || errno != EINTR { break }
        }
        // Reap before the pid is forgotten, so a late cancel never signals a recycled pid.
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        box.clear()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
