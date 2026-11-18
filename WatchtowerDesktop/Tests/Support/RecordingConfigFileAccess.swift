import Foundation
import WatchtowerCore

/// The live `ConfigFileAccess` with every step recorded in order: `lock`,
/// `read`, `write`, `unlock`. A `read` or `write` is recorded `…(locked)`
/// when the real lock file is held at that moment by another descriptor's
/// view — checked with a non-blocking `flock`, never a wait.
package final class RecordingConfigFileAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    package init() {}

    package var events: [String] {
        lock.withLock { recorded }
    }

    private func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    package var access: ConfigFileAccess {
        let live = ConfigFileAccess.live
        return ConfigFileAccess(
            withLock: { [self] path, body in
                try live.withLock(path) { token in
                    record("lock")
                    defer { record("unlock") }
                    try body(token)
                }
            },
            read: { [self] path in
                record(Self.isLocked(path) ? "read(locked)" : "read")
                return try live.read(path)
            },
            write: { [self] text, path, token in
                record(Self.isLocked(path) ? "write(locked)" : "write")
                try live.write(text, path, token)
            }
        )
    }

    /// Another descriptor cannot take the lock on `configPath` right now.
    package static func isLocked(_ configPath: String) -> Bool {
        let fd = open(ConfigFileLock.lockPath(for: configPath), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}
