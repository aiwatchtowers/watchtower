import AppKit
import GRDB
import WatchtowerCore

extension AppState {
    /// The Slack Live probe's status mirror, rebuilt with the database.
    func initSlackLive(dbPool: DatabasePool, cliRunner: (any CLIRunnerProtocol)?) {
        let center = SlackLiveStatusCenter(dbPool: dbPool, runner: cliRunner)
        // Off ↔ Live moves Catch-Up and Statistics and every Slack
        // feature's readiness (screens spec §2.2, §6).
        center.onStatusesChange = { [weak self] in
            guard let self else { return }
            await refreshConnectedSources()
            await readinessCenter.rereadDatabase()
        }
        slackLiveStatusCenter = center
        Task { await center.reload() }
        startSlackConnectListener()
    }

    /// The connect listener (`slack connect serve`, plan B #1709), once per
    /// process after the database opened; never under XCTest. On quit its
    /// stdin is closed, so the child frees port 18551 and exits.
    private func startSlackConnectListener() {
        guard slackConnectListener == nil,
              !Self.runsUnderXCTest,
              let streamer = ProcessCLILineStream.makeDefault() else { return }
        let host = SlackConnectListenerHost(streamer: streamer)
        slackConnectListener = host
        host.ensureRunning()
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { host.stop() }
        }
    }
}
