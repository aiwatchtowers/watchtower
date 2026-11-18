import Foundation

/// The `config.yaml` write lock, shared with every Go writer
/// (`config.WithWriteLock`, `internal/config/writelock.go`): an exclusive
/// `flock(2)` on `<configPath>.lock`. A writer takes it, re-reads the file
/// inside it, changes only its own keys and writes through
/// `ConfigFileWriter`, so a key another process wrote meanwhile is never
/// written back from a stale snapshot. Readers take no lock: the writer
/// replaces the file with an atomic rename.
package enum ConfigFileLock {
    /// Proof that `withLock` holds the lock for one config path. Only this
    /// file can make one, and it stops covering its path once the `withLock`
    /// body returns.
    package struct Token {
        fileprivate let state: HeldState

        /// The token is live and was issued for `configPath`.
        package func covers(_ configPath: String) -> Bool {
            state.isHeld && state.key == ConfigFileLock.key(configPath)
        }
    }

    package enum LockError: LocalizedError, Equatable {
        /// This process already holds the lock on the same path: the lock is
        /// not re-entrant, so a nested `withLock` fails at once rather than
        /// deadlocking on its own `flock`.
        case heldByThisProcess
        /// Another process held the lock for the whole bounded wait. Retryable.
        case busy
        /// The lock file could not be opened or locked (`errno`).
        case system(Int32)

        package var errorDescription: String? {
            switch self {
            case .busy: ConfigFileLock.busyMessage
            case .heldByThisProcess: "Settings are already being saved. Try again."
            case .system(let code): "config.yaml can't be locked for saving (\(String(cString: strerror(code))))."
            }
        }
    }

    /// What the owner sees when another Watchtower process (the CLI, the
    /// daemon) keeps the lock past the wait.
    package static let busyMessage = "Settings are being saved by another Watchtower process. Try again."

    /// How long `withLock` waits for another holder: it never blocks in
    /// `flock` (the Desktop calls it on the main actor), it retries a
    /// non-blocking `flock` `attempts` times, sleeping `interval` between
    /// tries — about 2 s with `.standard`. Tests inject `sleep`.
    package struct Wait: Sendable {
        package var attempts: Int
        package var interval: TimeInterval
        package var sleep: @Sendable (TimeInterval) -> Void

        package init(attempts: Int, interval: TimeInterval, sleep: @escaping @Sendable (TimeInterval) -> Void) {
            self.attempts = attempts
            self.interval = interval
            self.sleep = sleep
        }

        package static let standard = Self(attempts: 41, interval: 0.05) { Thread.sleep(forTimeInterval: $0) }
    }

    /// The lock file for `configPath` — the name Go uses too.
    package static func lockPath(for configPath: String) -> String {
        configPath + ".lock"
    }

    /// Runs `body` under the exclusive lock on `configPath` (the lock file is
    /// created `0600`, its directory when missing). Another holder is waited
    /// for as `wait` says, then `LockError.busy` is thrown and `body` never runs.
    package static func withLock<T>(
        configPath: String,
        wait: Wait = .standard,
        _ body: (Token) throws -> T
    ) throws -> T {
        let key = key(configPath)
        guard held.insert(key) else { throw LockError.heldByThisProcess }
        defer { held.remove(key) }

        try FileManager.default.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockFile = lockPath(for: configPath)
        let fd = open(lockFile, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LockError.system(errno) }
        defer { close(fd) }
        try acquire(fd, wait: wait)
        defer { flock(fd, LOCK_UN) }

        let state = HeldState(key: key)
        defer { state.release() }
        return try body(Token(state: state))
    }

    private static func acquire(_ fd: Int32, wait: Wait) throws {
        for attempt in 1...max(wait.attempts, 1) {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else { throw LockError.system(code) }
            if attempt < wait.attempts { wait.sleep(wait.interval) }
        }
        throw LockError.busy
    }

    /// One spelling per file, so `a/./config.yaml` and `a/config.yaml` are
    /// the same lock in the held set.
    fileprivate static func key(_ configPath: String) -> String {
        URL(fileURLWithPath: configPath).standardizedFileURL.path
    }

    private static let held = HeldPaths()
}

/// A token's liveness: released when its `withLock` body returns.
private final class HeldState: @unchecked Sendable {
    let key: String
    private let lock = NSLock()
    private var released = false

    init(key: String) { self.key = key }

    var isHeld: Bool { lock.withLock { !released } }
    func release() { lock.withLock { released = true } }
}

/// The config paths this process holds the lock on.
private final class HeldPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    /// False when `path` is already held.
    func insert(_ path: String) -> Bool { lock.withLock { paths.insert(path).inserted } }
    func remove(_ path: String) { _ = lock.withLock { paths.remove(path) } }
}
