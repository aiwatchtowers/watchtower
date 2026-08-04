import AppKit

/// Keeps at most one Watchtower instance alive.
///
/// A notification click is resolved by LaunchServices from the bundle identifier, and
/// it may pick a different registered on-disk copy of Watchtower.app than the one
/// already running (worktree builds share `com.watchtower.desktop`), launching a
/// second instance. The newcomer therefore defers: it activates the instance that is
/// already running and exits.
///
/// A notification response that launched this duplicate is dropped — the survivor is
/// only activated, not told why. Forwarding the payload to the running instance is a
/// known follow-up.
enum SingleInstanceGuard {
    /// One observed instance of the app, as seen through `NSRunningApplication`.
    struct InstanceInfo: Equatable {
        let pid: pid_t
        let launchDate: Date?
        let isTerminated: Bool
    }

    /// The pid of the instance this process should defer to, or nil when it should keep running.
    ///
    /// Deferral goes only to a strictly older *live* peer, under a strict total order:
    /// an unobservable launch date counts as older than any observed one (the peer
    /// started before we could see it), an earlier launch date is older, and ties break
    /// on the lower pid. That total order is what makes two instances racing each other
    /// agree on exactly one survivor.
    static func instanceToDefer(candidates: [InstanceInfo], current: InstanceInfo) -> pid_t? {
        let peers = candidates.filter { $0.pid != current.pid && !$0.isTerminated }
        guard let oldest = peers.min(by: isOlder), isOlder(oldest, current) else { return nil }
        return oldest.pid
    }

    private static func isOlder(_ lhs: InstanceInfo, _ rhs: InstanceInfo) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        default:
            return lhs.pid < rhs.pid
        }
    }

    @MainActor
    static func deferToRunningInstance() {
        // A bare `swift run` binary has no bundle identifier: without one there is
        // nothing to compare against, so it must never self-terminate.
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let current = NSRunningApplication.current

        guard let pid = instanceToDefer(
            candidates: running.map {
                InstanceInfo(pid: $0.processIdentifier, launchDate: $0.launchDate, isTerminated: $0.isTerminated)
            },
            current: InstanceInfo(pid: current.processIdentifier, launchDate: current.launchDate, isTerminated: false)
        ), let other = running.first(where: { $0.processIdentifier == pid }) else { return }

        let activated = other.activate()
        NSLog("SingleInstanceGuard: duplicate instance, deferring to pid %d (activate: %@); exiting", pid, activated ? "ok" : "denied")
        exit(0)
    }
}
