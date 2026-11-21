import AppKit
import ChatUI
import Foundation
import WatchtowerCore

extension AppState {
    /// Opens the Connections tab: `service`'s detail, or the overview for nil.
    /// A caller outside the main window (Settings) brings that window forward itself.
    func openConnections(_ service: ConnectionService? = nil) {
        selectedConnection = service
        selectedDestination = .connections
    }

    /// **Set up for my company** (company screens spec §2.1): the wizard's
    /// page in the Connections detail area; an entry (a Slack setup-record
    /// row, A19) opens it at that entry's step.
    func openCompanySetup(_ entry: CompanySetupWizardModel.Entry? = nil) {
        if let entry { companySetup.request(entry) }
        openConnections(.companySetup)
    }

    /// A Slack setup-record row (A19): **Add the link to the app** opens the
    /// wizard at Publish; false leaves the row to plan B's sheet (the other
    /// stages, or a sheet run still going, which the sheet shows).
    func routeSlackSetupRecord(_ record: SlackSetupRecord) -> Bool {
        guard !slackAppSetup.isRunning, let entry = CompanySetupWizardModel.Entry(record: record) else { return false }
        openCompanySetup(entry)
        return true
    }

    /// **Connect this Mac** after Publish; nil (the button hidden) while the
    /// company connect flow — the listener — is not up.
    var connectThisMacAction: (() -> Void)? {
        guard companyConnect != nil else { return nil }
        return { [weak self] in Task { await self?.connectThisMac() } }
    }

    /// Opens the same-bundle confirm (§3.1) for the published company: only
    /// what is not connected yet. Nothing before Publish went through.
    func connectThisMac() async {
        guard let flow = companyConnect, case let .done(published) = companySetup.publishState else { return }
        await flow.connectRest(slug: published.slug)
    }

    /// **Show file in Finder** for the set-aside draft, next to the company setups.
    func showCompanySetupFile(_ name: String) {
        guard let workspace = Constants.activeWorkspaceDir() else { return }
        let file = URL(fileURLWithPath: workspace).appendingPathComponent("company").appendingPathComponent(name)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// How often a sidebar click may re-read the accounts for the badge.
    static let connectionAccountsRefreshInterval: TimeInterval = 60

    /// Re-reads every service's accounts: a token expiry, a connect or a
    /// disconnect may have happened in another process (the daemon, the CLI).
    /// The Connections tab calls it on appear.
    func refreshConnectionAccounts(now: Date = Date()) {
        connectionAccountsReadAt = now
        for service in ConnectionService.services { refreshAccounts(of: service) }
        // The details group their accounts by the stored companies: a detail
        // opened straight (a Reconnect hand-off) must not see none (#1887 C3).
        reloadCompanies()
    }

    /// The badge's re-read on a sidebar click: at most once a minute.
    func refreshConnectionAccountsIfStale(now: Date = Date()) {
        if let last = connectionAccountsReadAt, now.timeIntervalSince(last) < Self.connectionAccountsRefreshInterval { return }
        refreshConnectionAccounts(now: now)
    }

    private func refreshAccounts(of service: ConnectionService) {
        switch service {
        case .slack: slackAccountsViewModel?.refresh()
        case .google: googleAccountsViewModel?.refresh()
        case .email: emailAccountsViewModel?.refresh()
        case .calendar: calendarAccountsViewModel?.refresh()
        case .jira: jiraAccountsViewModel?.refresh()
        case .linear: linearAccountsViewModel?.refresh()
        case .quickConnections: externalConnectionsViewModel?.refresh()
        case .companySetup: break
        }
    }

    /// Re-consents one Slack account from a failed send's card ("sign in
    /// again to grant send"): the same route as Connections → Slack →
    /// Reconnect (`slack login --account <id>`, or the connect flow, plan B
    /// A7). A route that continues on Connections → Slack (the flow in the
    /// browser, or the connect section) is `.handedOff`, never "done": the
    /// grant exists only once that flow connects.
    func reconnectSlack(accountID: Int64) async -> SlackReconnectOutcome {
        guard let vm = slackAccountsViewModel else {
            return .failed("Slack accounts are not loaded yet — open Connections → Slack.")
        }
        if vm.accounts.isEmpty {
            await vm.refreshAsync()
            // A failed read is not "no longer connected": say what failed.
            if vm.accounts.isEmpty, let readError = vm.readError { return .failed(readError) }
        }
        guard let account = vm.accounts.first(where: { $0.id == accountID }) else {
            return .failed("Slack account #\(accountID) is no longer connected.")
        }
        return reconnectOutcome(await vm.relogin(account))
    }

    /// How a card's Reconnect ended, from its own attempt's outcome; a
    /// hand-off brings Connections → Slack forward, where the flow's sheet
    /// and the connect section live. A sign-in the owner cancelled
    /// (`cancelCardSlackSignIn`, or Cancel on its Connections row) is
    /// `.cancelled`: no note, the card offers Reconnect Slack again.
    func reconnectOutcome(_ outcome: SlackAccountsViewModel.SignInOutcome) -> SlackReconnectOutcome {
        switch outcome {
        case .signedIn: return .signedIn
        case .cancelled: return .cancelled
        case let .failed(reason): return .failed(reason.isEmpty ? "Slack did not start the sign-in." : reason)
        case .handedOff:
            openConnections(.slack)
            bringMainWindowForward()
            return .handedOff
        }
    }

    /// Every service, in the overview's order.
    var connectionSummaries: [ConnectionSummary] {
        ConnectionService.services.map(connectionSummary)
    }

    /// The Connections row's badge: services that need the owner.
    var connectionsAttentionCount: Int {
        ConnectionSummary.attentionCount(connectionSummaries)
    }

    func connectionSummary(_ service: ConnectionService) -> ConnectionSummary {
        ConnectionSummary(
            service: service,
            accounts: connectionAccounts(service),
            readError: connectionReadError(service),
            blocked: !PolicySourceMap.allowed(service.rawValue, policy: managedPolicy.policy),
            notice: service == .slack ? slackOverviewNotice : companyBannerCardLine(service)
        )
    }

    /// "Shared app retiring" while an account syncs through the retired
    /// shared app (screens spec §5); not a problem.
    private var slackOverviewNotice: String? {
        guard let vm = slackAccountsViewModel else { return nil }
        return SlackModePresentation.overviewStatusLine(
            accounts: vm.accounts, sharedAppAccountIDs: vm.sharedAppAccountIDs)
    }

    private func connectionReadError(_ service: ConnectionService) -> String? {
        switch service {
        case .slack: slackAccountsViewModel?.readError
        case .google: googleAccountsViewModel?.readError
        case .email: emailAccountsViewModel?.readError
        case .calendar: calendarAccountsViewModel?.readError
        case .jira: jiraAccountsViewModel?.readError
        case .linear: linearAccountsViewModel?.readError
        case .quickConnections: externalConnectionsViewModel?.readError
        case .companySetup: nil
        }
    }

    /// nil while the service's view model is not loaded.
    private func connectionAccounts(_ service: ConnectionService) -> [ConnectionAccountState]? {
        switch service {
        case .slack: slackAccountsViewModel?.accounts.map(ConnectionAccountState.init)
        case .google: googleAccountsViewModel?.accounts.map(ConnectionAccountState.init)
        case .email: emailAccountsViewModel?.accounts.map(ConnectionAccountState.init)
        case .calendar: calendarAccountsViewModel?.accounts.map(ConnectionAccountState.init)
        case .jira: jiraAccountsViewModel?.accounts.map(ConnectionAccountState.init)
        case .linear: linearAccountsViewModel?.accounts.map(ConnectionAccountState.init)
        case .quickConnections: externalConnectionsViewModel?.connections.map(ConnectionAccountState.init)
        case .companySetup: []
        }
    }
}
