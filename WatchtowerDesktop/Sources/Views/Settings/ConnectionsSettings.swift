import SwiftUI
import WatchtowerCore

/// Connections tab — master list of external services on the left, the
/// selected service's accounts and settings on the right. Each detail view
/// owns its own sections.
struct ConnectionsSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    // Owned here, not by SlackConnectionDetail, so an in-flight Slack
    // connect/reconnect/disconnect survives switching to another service —
    // see SlackAuthFlowState's doc comment.
    @State private var slackFlow = SlackAuthFlowState()

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            List(ConnectionService.allCases, selection: $appState.settingsConnection) { service in
                row(service).tag(service)
            }
            // Not .sidebar: outside a NavigationSplitView its vibrancy
            // material bleeds up under the window's toolbar.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if isBlocked(appState.settingsConnection) {
                    SourceBlockedNotice()
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
        .onAppear {
            // Re-stat tokens/config: a connect or disconnect may have happened
            // outside this window (Calendar tab, Inbox banner, CLI).
            appState.slackAccountsViewModel?.refresh()
            appState.jiraAccountsViewModel?.refresh()
            appState.linearAccountsViewModel?.refresh()
            appState.emailAccountsViewModel?.refresh()
            appState.calendarAccountsViewModel?.refresh()
            appState.googleAccountsViewModel?.refresh()
            appState.externalConnectionsViewModel?.refresh()
        }
    }

    private func row(_ service: ConnectionService) -> some View {
        HStack {
            Label(service.label, systemImage: service.icon)
            Spacer()
            if accountCount(service) > 0 {
                Text("\(accountCount(service))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isBlocked(service) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(SourceBlockedNotice.title)
            } else {
                Circle()
                    .fill(status(service).color)
                    .frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.settingsConnection {
        case .slack: SlackConnectionDetail(config: config, flow: slackFlow)
        case .google: GoogleConnectionDetail(config: config)
        case .email: EmailConnectionDetail()
        case .calendar: CalendarConnectionDetail()
        case .jira: JiraConnectionDetail()
        case .linear: LinearConnectionDetail()
        case .quickConnections: QuickConnectionsDetail()
        }
    }

    /// The organization's policy forbids the service's source (#608).
    private func isBlocked(_ service: ConnectionService) -> Bool {
        !PolicySourceMap.allowed(service.rawValue, policy: appState.managedPolicy.policy)
    }

    // MARK: - Row status

    private func accountCount(_ service: ConnectionService) -> Int {
        switch service {
        case .slack: appState.slackAccountsViewModel?.accounts.count ?? 0
        case .google: appState.googleAccountsViewModel?.accounts.count ?? 0
        case .email: appState.emailAccountsViewModel?.accounts.count ?? 0
        case .calendar: appState.calendarAccountsViewModel?.accounts.count ?? 0
        case .jira: appState.jiraAccountsViewModel?.accounts.count ?? 0
        case .linear: appState.linearAccountsViewModel?.accounts.count ?? 0
        case .quickConnections: appState.externalConnectionsViewModel?.connections.count ?? 0
        }
    }

    private func status(_ service: ConnectionService) -> ConnectionStatus {
        switch service {
        case .slack:
            guard let vm = appState.slackAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.enabledFilteredStatus(vm.accounts.map { ($0.isOK, $0.enabled) })
        case .google:
            guard let vm = appState.googleAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.status(okFlags: vm.accounts.map(\.isOK))
        case .email:
            guard let vm = appState.emailAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.status(okFlags: vm.accounts.map(\.isOK))
        case .calendar:
            guard let vm = appState.calendarAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.status(okFlags: vm.accounts.map(\.isOK))
        case .jira:
            guard let vm = appState.jiraAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.enabledFilteredStatus(vm.accounts.map { ($0.isOK, $0.enabled) })
        case .linear:
            guard let vm = appState.linearAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.enabledFilteredStatus(vm.accounts.map { ($0.isOK, $0.enabled) })
        case .quickConnections:
            guard let vm = appState.externalConnectionsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.enabledFilteredStatus(vm.connections.map { ($0.isOK, $0.enabled) })
        }
    }
}

/// The line over a connection the organization's policy forbids (#608): its
/// accounts stay but no longer sync, and their data is kept.
struct SourceBlockedNotice: View {
    static let title = "Blocked by your organization"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Label(Self.title, systemImage: "lock.fill")
                .font(.callout.weight(.medium))
            Text("Your organization's policy does not allow this source. Existing accounts stop syncing and keep their data; "
                + "nothing new can be connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.horizontal, Spacing.page)
        .padding(.top, Spacing.medium)
    }
}
