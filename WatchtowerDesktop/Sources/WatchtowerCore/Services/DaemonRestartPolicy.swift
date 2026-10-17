/// Whether an account change (a Slack/Google/Jira connection added or
/// removed) re-wires the daemon right away. Settings restarts it, since
/// syncers are wired only at daemon startup; onboarding defers, because a
/// restart always starts the daemon and its first cycle would run a full AI
/// pass over the default-on features in the middle of setup — onboarding
/// starts the daemon itself once it completes.
package enum DaemonRestartPolicy: Sendable {
    case restart
    case deferred

    /// Kicks off `daemon.restartLogging()` under `.restart` and returns its
    /// task (so a caller can await it); does nothing under `.deferred`.
    package func apply(using daemon: any DaemonRestarting) -> Task<Void, Never>? {
        switch self {
        case .restart:
            return Task { await daemon.restartLogging() }
        case .deferred:
            return nil
        }
    }
}

/// The daemon-restart seam the account view models restart through, so
/// tests can count restarts instead of spawning the CLI.
package protocol DaemonRestarting: Sendable {
    func restartLogging() async
}

/// Production `DaemonRestarting`: `DaemonManager.restartLoggingQueued()`,
/// on the app's one daemon start queue.
package struct LiveDaemonRestarter: DaemonRestarting {
    private let queue: DaemonStartQueue
    private let restart: @Sendable () async throws -> Void

    /// Tests pass their own queue and restart; production uses the shared
    /// queue and `DaemonManager.restart()`.
    package init(
        queue: DaemonStartQueue = .shared,
        restart: @escaping @Sendable () async throws -> Void = { try await DaemonManager.restart() }
    ) {
        self.queue = queue
        self.restart = restart
    }

    package func restartLogging() async {
        await queue.restartLogging(restart)
    }
}
