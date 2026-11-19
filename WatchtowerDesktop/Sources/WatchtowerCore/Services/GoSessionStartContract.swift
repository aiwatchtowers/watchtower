import Darwin
import Foundation

/// What the Desktop shares with Go's `workbench session start` (Go hub 3
/// Task 8): the per-workbench placement lock and the reasons the Desktop
/// tells apart. The Go twin is `internal/sessionstart/contract.go`; both are
/// pinned by `internal/sessionstart/testdata/desktop_contract.json`.
package enum GoSessionStartContract {
    /// agent_error's start of a row Go could not move into its worktree.
    package static let moveFailedPrefix = "Could not move the session into its worktree: "
    /// start_notice's start for a placed row whose setup command never ran.
    package static let setupNotRunPrefix = "The worktree setup command did not run — run it in the terminal: "
    /// `session start`'s exit code for a missing agent binary.
    package static let agentNotFoundExit: Int32 = 3

    /// agent_error when the agent's binary is missing.
    package static func agentNotFoundReason(_ agent: String) -> String { "\(agent) was not found" }

    /// The workbench's placement lock beside the database: every start —
    /// Go's finish, the Desktop's own launch path — holds it from deciding
    /// the place until the run is in the session host.
    package static func lockPath(databasePath: String, workbenchID: Int64) -> String {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            .appendingPathComponent("workbench-\(workbenchID).place.lock").path
    }
}

/// An exclusive advisory flock on a placement lock file (Go's
/// `fsutil.LockFile` on the same path). Taken without blocking, retried
/// every `step` until `deadline`; nil when it could not be taken or the
/// task was cancelled meanwhile. The kernel drops it if the app dies.
package final class PlacementLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    package static func acquire(
        path: String, waitingUpTo wait: Duration, step: Duration = .milliseconds(50)
    ) async -> PlacementLock? {
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return PlacementLock(fd: fd) }
            guard errno == EWOULDBLOCK || errno == EINTR, clock.now < deadline else {
                Darwin.close(fd)
                return nil
            }
            do {
                try await Task.sleep(for: step)
            } catch {
                Darwin.close(fd) // cancelled: never a hot spin
                return nil
            }
        }
    }

    package func release() {
        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
