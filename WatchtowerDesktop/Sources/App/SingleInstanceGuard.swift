import AppKit
import Foundation

/// Keeps at most one Watchtower instance alive.
///
/// A notification click is resolved by LaunchServices from the bundle identifier, and
/// it may pick a different registered on-disk copy of Watchtower.app than the one
/// already running (worktree builds share `com.watchtower.desktop`), launching a
/// second instance. The newcomer therefore defers: it activates the instance that is
/// already running and exits.
enum SingleInstanceGuard {
    /// The pid of another instance to defer to, or nil when this process should keep running.
    /// A missing bundle identifier (a bare `swift run` binary) never yields a duplicate.
    static func duplicatePID(bundleID: String?, runningPIDs: [pid_t], currentPID: pid_t) -> pid_t? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return runningPIDs.first { $0 != currentPID }
    }

    @MainActor
    static func terminateIfDuplicate() {
        let bundleID = Bundle.main.bundleIdentifier
        let running = bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        let currentPID = ProcessInfo.processInfo.processIdentifier

        guard let pid = duplicatePID(
            bundleID: bundleID,
            runningPIDs: running.map(\.processIdentifier),
            currentPID: currentPID
        ) else { return }

        running.first { $0.processIdentifier == pid }?.activate()
        exit(0)
    }
}
