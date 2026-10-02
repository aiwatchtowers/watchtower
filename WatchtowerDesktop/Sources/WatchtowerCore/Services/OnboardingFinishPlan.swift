import Foundation

/// The daemon control onboarding's finish needs; `DaemonManager` in the
/// app, a fake in tests.
@MainActor
package protocol OnboardingDaemonControl: AnyObject {
    func daemonIsRunning() -> Bool
    func startDaemon() async
    func restartDaemon() async
}

/// Where the app opens once onboarding is done, and how the daemon is
/// brought up for it.
package enum OnboardingFinishPlan {
    package enum Landing: Equatable, Sendable {
        case catchUp, workbench, chat
    }

    /// Work communication with a Slack or mail source → Catch-Up (its tab
    /// only shows with one); else Development → Workbench; else AI Chat.
    package static func landing(goals: Set<OnboardingGoal>, connected: ConnectedSources) -> Landing {
        if goals.contains(.workCommunication), connected.slack || connected.mail { return .catchUp }
        if goals.contains(.development) { return .workbench }
        return .chat
    }

    /// Finish is the one place onboarding touches the daemon: it starts one,
    /// or restarts a running one once so it picks up the feature set and
    /// accounts the steps just wrote. The daemon's first cycle syncs and
    /// runs every enabled pipeline itself.
    @MainActor
    package static func bringUpDaemon(_ daemon: any OnboardingDaemonControl) async {
        if daemon.daemonIsRunning() {
            await daemon.restartDaemon()
        } else {
            await daemon.startDaemon()
        }
    }

    /// Catch-Up's empty state while the first sync runs, nil when no sync
    /// is running.
    package static func firstSyncText(
        progress: SyncProgress?,
        historyDays: Int,
        now: Date = Date()
    ) -> (title: String, detail: String)? {
        guard let progress, progress.isSyncing(now: now) else { return nil }
        let days = historyDays == 1 ? "day" : "\(historyDays) days"
        return ("Syncing Slack for the last \(days) — usually 3–5 min", progress.summary)
    }
}

extension DaemonManager: OnboardingDaemonControl {
    package func daemonIsRunning() -> Bool {
        Self.checkDaemonRunning()
    }

    package func restartDaemon() async {
        await Self.restartLogging()
        checkStatus()
    }
}
