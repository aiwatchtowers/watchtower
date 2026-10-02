import Foundation

/// The daemon control onboarding's finish and Reset LLM data need;
/// `DaemonManager` in the app, a fake in tests.
@MainActor
package protocol DaemonControl: AnyObject {
    func daemonIsRunning() -> Bool
    /// `sync --daemon --detach`; false (and the reason logged/surfaced by
    /// the implementation) on failure.
    func startDetached() async -> Bool
    /// Stops the daemon, waits for it to die, starts it again.
    func restartWaiting() async throws
    func stopDaemonNow() async
    /// Waits (bounded) for a stopped daemon's process to be gone; throws
    /// when it outlives the wait.
    func waitUntilStopped() async throws
}

/// Where the app opens once onboarding is done, how the daemon is brought up
/// for it, and Catch-Up's first-sync line.
package enum OnboardingFinishPlan {
    package enum Landing: Equatable, Sendable {
        case catchUp, workbench, chat
    }

    /// Work communication while the Catch-Up tab shows (its feature on and
    /// a Slack or mail source) → Catch-Up; else Development → Workbench;
    /// else AI Chat.
    package static func landing(goals: Set<OnboardingGoal>, catchUpVisible: Bool) -> Landing {
        if goals.contains(.workCommunication), catchUpVisible { return .catchUp }
        if goals.contains(.development) { return .workbench }
        return .chat
    }

    /// Finish is the one place onboarding touches the daemon: it starts one,
    /// or restarts a running one once so it picks up the feature set and
    /// accounts the steps just wrote. The daemon's first cycle syncs and
    /// runs every enabled pipeline itself. Returns whether it is up.
    @MainActor
    package static func bringUpDaemon(_ daemon: any DaemonControl) async -> Bool {
        guard daemon.daemonIsRunning() else { return await daemon.startDetached() }
        do {
            try await daemon.restartWaiting()
            return true
        } catch {
            return false
        }
    }

    /// Catch-Up's empty state during the very first sync: a sync is running
    /// and none has finished yet (`lastSyncTime` nil). nil otherwise.
    package static func firstSyncText(
        progress: SyncProgress?,
        lastSyncTime: Date?,
        historyDays: Int,
        connected: ConnectedSources,
        now: Date = Date()
    ) -> (title: String, detail: String)? {
        guard lastSyncTime == nil, let progress, progress.isSyncing(now: now) else { return nil }
        let days = historyDays == 1 ? "day" : "\(historyDays) days"
        let title = switch (connected.slack, connected.mail) {
        case (true, true): "Syncing Slack and mail for the last \(days) — usually 3–5 min"
        case (true, false): "Syncing Slack for the last \(days) — usually 3–5 min"
        case (false, true): "Syncing mail — usually 3–5 min"
        case (false, false): "Syncing your sources — usually 3–5 min"
        }
        return (title, progress.summary)
    }
}

/// The daemon's run-time stamps (`internal/daemon`): when it last built
/// people cards, a briefing, ideas, stream digests, and how many attempts
/// today's budgets have used. Removing them makes the next cycle regenerate
/// those at once instead of waiting for their cadence.
package enum DaemonStampFiles {
    package static let names = [
        "last_people.txt", "last_briefing.txt", "last_ideas.txt", "last_streams.txt",
        "people_attempts.txt", "briefing_attempts.txt", "day_plan_attempts.txt", "rollup_attempts.txt"
    ]

    /// Deletes every stamp in `workspaceDir`; a missing one is fine.
    package static func clear(in workspaceDir: String, fileManager: FileManager = .default) throws {
        for name in names {
            let path = (workspaceDir as NSString).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: path) else { continue }
            try fileManager.removeItem(atPath: path)
        }
    }
}

extension DaemonManager: DaemonControl {
    package func daemonIsRunning() -> Bool {
        Self.checkDaemonRunning()
    }

    package func startDetached() async -> Bool {
        await startDaemon()
        return errorMessage == nil
    }

    package func restartWaiting() async throws {
        do {
            try await Self.restart()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            checkStatus()
            throw error
        }
        checkStatus()
    }

    package func stopDaemonNow() async {
        resolvePathIfNeeded()
        await stopDaemon()
    }

    package func waitUntilStopped() async throws {
        try await Self.waitForDaemonExit()
        checkStatus()
    }
}
