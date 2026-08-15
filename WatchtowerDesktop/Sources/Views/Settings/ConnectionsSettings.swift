import SwiftUI

enum ConnectionStatus: Equatable {
    case connected, error, notConfigured

    var color: Color {
        switch self {
        case .connected: .green
        case .error: .red
        case .notConfigured: .gray
        }
    }
}

enum ConnectionStatusLogic {
    /// problemCount = accounts whose status is not OK (error/revoked/removed-pending).
    static func derive(okCount: Int, problemCount: Int) -> ConnectionStatus {
        if problemCount > 0 { return .error }
        return okCount > 0 ? .connected : .notConfigured
    }
}

enum ConnectionService: String, CaseIterable, Identifiable {
    case slack, google, email, calendar, jira
    var id: String { rawValue }

    var label: String {
        switch self {
        case .slack: "Slack"
        case .google: "Google"
        case .email: "Email"
        case .calendar: "Calendar"
        case .jira: "Jira"
        }
    }

    var icon: String {
        switch self {
        case .slack: "number"
        case .google: "g.circle"
        case .email: "envelope"
        case .calendar: "calendar"
        case .jira: "checklist"
        }
    }
}

/// Connections tab — master list of external services on the left, the
/// selected service's accounts and settings on the right. Each detail view
/// owns the sections moved verbatim from the old General tab.
struct ConnectionsSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    @State private var selected: ConnectionService = .slack

    var body: some View {
        HStack(spacing: 0) {
            List(ConnectionService.allCases, selection: $selected) { service in
                row(service).tag(service)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
        .onAppear {
            // Re-stat tokens/config: a connect or disconnect may have happened
            // outside this window (Calendar tab, Inbox banner, CLI).
            appState.slackAccountsViewModel?.refresh()
            appState.jiraAccountsViewModel?.refresh()
            appState.emailAccountsViewModel?.refresh()
            appState.calendarAccountsViewModel?.refresh()
            appState.googleAccountsViewModel?.refresh()
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
            Circle()
                .fill(status(service).color)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .slack: SlackConnectionDetail(config: config)
        case .google: GoogleConnectionDetail(config: config)
        case .email: EmailConnectionDetail()
        case .calendar: CalendarConnectionDetail()
        case .jira: JiraConnectionDetail()
        }
    }

    // MARK: - Row status

    private func accountCount(_ service: ConnectionService) -> Int {
        switch service {
        case .slack: appState.slackAccountsViewModel?.accounts.count ?? 0
        case .google: appState.googleAccountsViewModel?.accounts.count ?? 0
        case .email: appState.emailAccountsViewModel?.accounts.count ?? 0
        case .calendar: appState.calendarAccountsViewModel?.accounts.count ?? 0
        case .jira: appState.jiraAccountsViewModel?.accounts.count ?? 0
        }
    }

    private func status(_ service: ConnectionService) -> ConnectionStatus {
        switch service {
        case .slack:
            guard let vm = appState.slackAccountsViewModel else { return .notConfigured }
            let enabled = vm.accounts.filter(\.enabled)
            return ConnectionStatusLogic.derive(
                okCount: enabled.filter(\.isOK).count,
                problemCount: enabled.filter { !$0.isOK }.count
            )
        case .google:
            guard let vm = appState.googleAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.derive(
                okCount: vm.accounts.filter(\.isOK).count,
                problemCount: vm.accounts.filter { !$0.isOK }.count
            )
        case .email:
            guard let vm = appState.emailAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.derive(
                okCount: vm.accounts.filter(\.isOK).count,
                problemCount: vm.accounts.filter { !$0.isOK }.count
            )
        case .calendar:
            guard let vm = appState.calendarAccountsViewModel else { return .notConfigured }
            return ConnectionStatusLogic.derive(
                okCount: vm.accounts.filter(\.isOK).count,
                problemCount: vm.accounts.filter { !$0.isOK }.count
            )
        case .jira:
            guard let vm = appState.jiraAccountsViewModel else { return .notConfigured }
            let enabled = vm.accounts.filter(\.enabled)
            return ConnectionStatusLogic.derive(
                okCount: enabled.filter(\.isOK).count,
                problemCount: enabled.filter { !$0.isOK }.count
            )
        }
    }
}
