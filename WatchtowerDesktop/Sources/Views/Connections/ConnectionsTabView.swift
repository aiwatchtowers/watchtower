import SwiftUI
import WatchtowerCore

/// The Connections tab: the overview of every service, or one service's
/// detail beside the service list (`AppState.selectedConnection`).
struct ConnectionsTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let service = appState.selectedConnection {
                ConnectionsDetailSplit(service: service)
            } else {
                ConnectionsOverview()
            }
        }
        // A connect or disconnect may have happened elsewhere (the Calendar
        // tab, an Inbox banner, the CLI) or a token expired in the daemon.
        .onAppear { appState.refreshConnectionAccounts() }
    }
}

/// The service list beside the open service's detail; the existing detail
/// views, unchanged.
struct ConnectionsDetailSplit: View {
    @Environment(AppState.self) private var appState
    let service: ConnectionService

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            List(selection: $appState.selectedConnection) {
                Section("Sources") {
                    ForEach(ConnectionService.sources) { row($0).tag(Optional($0)) }
                }
                Section("Tools for AI") {
                    ForEach(ConnectionService.aiTools) { row($0).tag(Optional($0)) }
                }
            }
            // Not .sidebar: outside a NavigationSplitView its vibrancy
            // material bleeds up under the window's toolbar.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: PaneWidth.sideListIdeal)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                if appState.connectionSummary(service).blocked {
                    SourceBlockedNotice()
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: appState.sharedConfig) }
    }

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Button {
                appState.selectedConnection = nil
            } label: {
                Label("All Connections", systemImage: "chevron.left")
            }
            .buttonStyle(.kitQuiet)
            Spacer()
        }
        .padding(.horizontal, Spacing.page)
        .padding(.top, Spacing.medium)
    }

    private func row(_ service: ConnectionService) -> some View {
        let summary = appState.connectionSummary(service)
        return HStack {
            Label(service.label, systemImage: service.icon)
            Spacer()
            if summary.accountCount > 0 {
                Text("\(summary.accountCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ConnectionStatusMark(summary: summary)
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var detail: some View {
        switch service {
        case .slack: SlackConnectionDetail(config: appState.sharedConfig, flow: appState.slackAuthFlow)
        case .google: GoogleConnectionDetail(config: appState.sharedConfig)
        case .email: EmailConnectionDetail()
        case .calendar: CalendarConnectionDetail()
        case .jira: JiraConnectionDetail()
        case .linear: LinearConnectionDetail()
        case .quickConnections: QuickConnectionsDetail()
        }
    }
}

/// A service's status dot, or a lock when the organization's policy blocks it.
struct ConnectionStatusMark: View {
    let summary: ConnectionSummary

    var body: some View {
        if summary.blocked {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(SourceBlockedNotice.title)
        } else {
            Circle()
                .fill(summary.status.color)
                .frame(width: Spacing.regular, height: Spacing.regular)
        }
    }
}
