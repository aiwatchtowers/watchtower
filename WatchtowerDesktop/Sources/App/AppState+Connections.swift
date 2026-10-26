import Foundation
import WatchtowerCore

extension AppState {
    /// Opens the Connections tab: `service`'s detail, or the overview for nil.
    /// A caller outside the main window (Settings) brings that window forward itself.
    func openConnections(_ service: ConnectionService? = nil) {
        selectedConnection = service
        selectedDestination = .connections
    }

    /// How often a sidebar click may re-read the accounts for the badge.
    static let connectionAccountsRefreshInterval: TimeInterval = 60

    /// Re-reads every service's accounts: a token expiry, a connect or a
    /// disconnect may have happened in another process (the daemon, the CLI).
    /// The Connections tab calls it on appear.
    func refreshConnectionAccounts(now: Date = Date()) {
        connectionAccountsReadAt = now
        for service in ConnectionService.allCases { refreshAccounts(of: service) }
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
        }
    }

    /// Re-consents one Slack account from a failed send's card ("sign in
    /// again to grant send"): the same `slack login --account <id>` flow as
    /// Connections → Slack → Reconnect. Returns why it failed (nil on success or
    /// a cancelled sign-in) so the card can say so.
    func reconnectSlack(accountID: Int64) async -> String? {
        guard let vm = slackAccountsViewModel else {
            return "Slack accounts are not loaded yet — open Connections → Slack."
        }
        if vm.accounts.isEmpty {
            await vm.refreshAsync()
            // A failed read is not "no longer connected": say what failed.
            if vm.accounts.isEmpty, let readError = vm.readError { return readError }
        }
        guard let account = vm.accounts.first(where: { $0.id == accountID }) else {
            return "Slack account #\(accountID) is no longer connected."
        }
        await vm.relogin(account)
        return vm.error
    }

    /// Every service, in the overview's order.
    var connectionSummaries: [ConnectionSummary] {
        ConnectionService.allCases.map(connectionSummary)
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
            blocked: !PolicySourceMap.allowed(service.rawValue, policy: managedPolicy.policy)
        )
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
        }
    }
}
