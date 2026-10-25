import WatchtowerCore

extension AppState {
    /// Opens the Connections tab: `service`'s detail, or the overview for nil.
    /// A caller outside the main window (Settings) brings that window forward itself.
    func openConnections(_ service: ConnectionService? = nil) {
        selectedConnection = service
        selectedDestination = .connections
    }

    /// Re-reads every service's accounts: a token expiry, a connect or a
    /// disconnect may have happened in another process (the daemon, the CLI).
    func refreshConnectionAccounts() {
        slackAccountsViewModel?.refresh()
        jiraAccountsViewModel?.refresh()
        linearAccountsViewModel?.refresh()
        emailAccountsViewModel?.refresh()
        calendarAccountsViewModel?.refresh()
        googleAccountsViewModel?.refresh()
        externalConnectionsViewModel?.refresh()
    }

    /// Re-consents one Slack account from a failed send's card ("sign in
    /// again to grant send"): the same `slack login --account <id>` flow as
    /// Connections → Slack → Reconnect. Returns why it failed (nil on success or
    /// a cancelled sign-in) so the card can say so.
    func reconnectSlack(accountID: Int64) async -> String? {
        guard let vm = slackAccountsViewModel else {
            return "Slack accounts are not loaded yet — open Connections → Slack."
        }
        if vm.accounts.isEmpty { await vm.refreshAsync() }
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
            blocked: !PolicySourceMap.allowed(service.rawValue, policy: managedPolicy.policy)
        )
    }

    /// nil while the service's view model is not loaded.
    private func connectionAccounts(_ service: ConnectionService) -> [ConnectionAccountState]? {
        switch service {
        case .slack:
            slackAccountsViewModel?.accounts.map {
                ConnectionAccountState(name: $0.displayName, isOK: $0.isOK, enabled: $0.enabled, status: $0.status, error: $0.error)
            }
        case .google:
            googleAccountsViewModel?.accounts.map {
                ConnectionAccountState(name: $0.displayName, isOK: $0.isOK, status: $0.status, error: $0.error)
            }
        case .email:
            emailAccountsViewModel?.accounts.map {
                ConnectionAccountState(name: $0.displayName, isOK: $0.isOK, status: $0.status, error: $0.error)
            }
        case .calendar:
            calendarAccountsViewModel?.accounts.map {
                ConnectionAccountState(name: $0.displayName, isOK: $0.isOK, status: $0.status, error: $0.error)
            }
        case .jira:
            jiraAccountsViewModel?.accounts.map {
                ConnectionAccountState(name: $0.displayName, isOK: $0.isOK, enabled: $0.enabled, status: $0.status, error: $0.error)
            }
        case .linear:
            linearAccountsViewModel?.accounts.map {
                ConnectionAccountState(name: $0.displayName, isOK: $0.isOK, enabled: $0.enabled, status: $0.status, error: $0.error)
            }
        case .quickConnections:
            externalConnectionsViewModel?.connections.map {
                ConnectionAccountState(name: $0.name, isOK: $0.isOK, enabled: $0.enabled, status: $0.status, error: $0.error)
            }
        }
    }
}
