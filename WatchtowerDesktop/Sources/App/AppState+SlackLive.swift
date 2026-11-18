import AppKit
import GRDB
import WatchtowerCore

extension AppState {
    /// The Slack Live probe's status mirror, rebuilt with the database.
    func initSlackLive(dbPool: DatabasePool, cliRunner: (any CLIRunnerProtocol)?) {
        let center = SlackLiveStatusCenter(dbPool: dbPool, runner: cliRunner)
        slackLiveStatusCenter = center
        Task { await center.reload() }
        startSlackConnectListener()
    }

    /// The Slack accounts and the connect flow, for onboarding's Connect step
    /// too: a build with no Slack app of its own connects there by link, code
    /// or MDM row (A13). The listener is the one the app keeps afterwards
    /// (`initSlackLive` finds it running).
    func initSlackAccountsAndConnectFlow(dbPool: DatabasePool) {
        initSlackAccounts(dbPool: dbPool)
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
        // The flow consumes the host's events from its first line on.
        slackConnectFlow = makeSlackConnectFlow(host: host)
        host.ensureRunning()
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { host.stop() }
        }
    }

    /// The connect flow on the listener (plan B Task 14): a clicked link
    /// brings the app forward on Connections → Slack with the confirm; a
    /// written account reloads the list and re-wires the daemon. One flow at
    /// a time with the legacy sign-ins (`SlackAuthFlowState`, `slack login`).
    func makeSlackConnectFlow(host: SlackConnectListenerHost) -> SlackConnectFlowModel {
        let flow = SlackConnectFlowModel(host: host)
        flow.onLink = { [weak self] in
            // Onboarding's Connect step shows the confirm in its Slack sheet.
            if self?.needsOnboarding == false { self?.openConnections(.slack) }
            self?.bringMainWindowForward()
        }
        flow.onConnected = { [weak self] _ in
            guard let self else { return }
            slackAccountsViewModel?.connectFlowWroteAccount(daemonPolicy: accountDaemonPolicy)
        }
        flow.externalBusy = { [weak self] in
            guard let self else { return false }
            return slackAuthFlow.reconnecting || slackAccountsViewModel?.isConnecting == true
        }
        // The accounts VM exists by now (wireOnboardingDatabase runs before
        // wireAppDatabase on every launch path); its Re-login routes here.
        slackAccountsViewModel?.connectFlow = flow
        // Set up for my company's admin connect runs on this flow too (A4).
        slackAppSetup.connector = SlackSetupConnector(flow: flow)
        return flow
    }
}
