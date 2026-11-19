import Foundation
import WatchtowerCore

extension AppState {
    /// The company connect flow on the listener (#1887 Task 23): a company
    /// link brings the app forward on Connections with the confirm; a stored
    /// bundle or an ended chain re-reads the accounts and re-wires the
    /// daemon. One flow at a time with the Slack connect flow and the legacy
    /// sign-ins. Slack's connect field hands a company link or code here (A20).
    func makeCompanyConnectFlow(
        host: SlackConnectListenerHost,
        makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)? = { AppState.slackLineStream() }
    ) -> CompanyConnectFlowModel {
        let flow = CompanyConnectFlowModel(host: host, makeStreamer: makeStreamer)
        flow.onShow = { [weak self] in
            guard let self else { return }
            // During onboarding the sheet waits; it shows once onboarding ends
            // (`showPendingSlackConnect`).
            if !needsOnboarding { showConnectionsForCompanySheet() }
            bringMainWindowForward()
        }
        flow.onCompaniesChanged = { [weak self] in self?.refreshConnectionAccounts() }
        flow.onChainEnded = { [weak self] in
            guard let self else { return }
            refreshConnectionAccounts()
            slackAccountsViewModel?.connectFlowWroteAccount(daemonPolicy: accountDaemonPolicy)
        }
        flow.externalBusy = { [weak self] in
            guard let self else { return false }
            return slackConnectFlow?.isRunning == true || slackAuthFlow.reconnecting
                || slackAccountsViewModel?.isConnecting == true
        }
        slackConnectFlow?.companyPaste = { [weak flow] text in
            await flow?.paste(text) ?? CompanyConnectFlowModel.codeInvalid
        }
        return flow
    }

    /// The company sheet lives on the Connections tab, over whichever of its
    /// pages is open: another tab switches to the overview.
    func showConnectionsForCompanySheet() {
        if selectedDestination != .connections { openConnections() }
    }
}
