import AppKit

/// Keeps at most one Watchtower instance alive.
///
/// A notification click is resolved by LaunchServices from the bundle identifier, and
/// it may pick a different registered on-disk copy of Watchtower.app than the one
/// already running (worktree builds share `com.watchtower.desktop`), launching a
/// second instance. The newcomer therefore defers: it activates the instance that is
/// already running and exits.
///
/// A notification response that launched this duplicate is not dropped: the duplicate
/// stays alive headless for a short grace window (5 s, applied in `WatchtowerApp.init`)
/// so the response can arrive and be forwarded to the survivor before it exits.
///
/// Deferral goes only to a *certainly older live* peer: when the two launch dates are
/// not comparable (one observable, the other not), this process keeps running.
enum SingleInstanceGuard {
    /// One observed instance of the app, as seen through `NSRunningApplication`.
    struct InstanceInfo {
        let pid: pid_t
        let launchDate: Date?
        let isTerminated: Bool
    }

    /// The pid of the instance this process should defer to, or nil when it should keep running.
    ///
    /// A peer qualifies only when it is live and *certainly* older than this process;
    /// an observability mismatch between the two launch dates is not evidence of age,
    /// so it never triggers a deferral. Among qualifying peers the lowest pid wins, so
    /// the choice is stable whichever side asks.
    static func instanceToDefer(candidates: [InstanceInfo], current: InstanceInfo) -> pid_t? {
        let peers = candidates.filter { $0.pid != current.pid && !$0.isTerminated }
        return peers.filter { certainlyOlder($0, than: current) }.map(\.pid).min()
    }

    /// Comparable views only: a launch date visible on one side but not the other is an
    /// observability artifact of a mid-launch peer, not evidence of age. On a mismatch we
    /// never defer — two racing instances may then both survive briefly (a recoverable
    /// duplicate, and the LSMultipleInstancesProhibited layer's case), but they can never
    /// BOTH exit, which is the unrecoverable direction. The both-nil pid tie-break assumes
    /// pids are assigned in launch order; a pid-counter wrap between two simultaneous cold
    /// launches combined with asymmetric observability could still defeat it — accepted,
    /// as no per-process ordering over inconsistent views can close that corner.
    private static func certainlyOlder(_ peer: InstanceInfo, than current: InstanceInfo) -> Bool {
        switch (peer.launchDate, current.launchDate) {
        case let (p?, c?): return p < c || (p == c && peer.pid < current.pid)
        case (nil, nil):   return peer.pid < current.pid
        default:           return false
        }
    }

    /// The live instance this process should defer to, or nil when it should keep
    /// running. Deciding and acting are separate: what a duplicate does about it
    /// (forward, then exit) belongs to `WatchtowerApp.init`.
    @MainActor
    static func runningInstanceToDeferTo() -> NSRunningApplication? {
        // A bare `swift run` binary has no bundle identifier: without one there is
        // nothing to compare against, so it must never self-terminate.
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return nil }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let current = NSRunningApplication.current

        guard let pid = instanceToDefer(
            candidates: running.map {
                InstanceInfo(pid: $0.processIdentifier, launchDate: $0.launchDate, isTerminated: $0.isTerminated)
            },
            current: InstanceInfo(pid: current.processIdentifier, launchDate: current.launchDate, isTerminated: false)
        ) else { return nil }

        return running.first { $0.processIdentifier == pid }
    }
}
