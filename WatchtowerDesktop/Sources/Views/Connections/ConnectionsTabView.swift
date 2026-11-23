import SwiftUI
import WatchtowerCore

/// The Connections tab: the overview of every service, or one service's
/// detail beside the service list (`AppState.selectedConnection`).
struct ConnectionsTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let service = appState.selectedConnection {
                    ConnectionsDetailSplit(service: service)
                } else {
                    ConnectionsOverview()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The connect assistant (#2133 §7): the 380 pt panel on the right.
            if let session = appState.connectAssistantPanelSession {
                Rectangle().fill(Stroke.hairlineColor).frame(width: Stroke.hairline)
                ConnectAssistantHost(session: session)
            }
        }
        // A connect or disconnect may have happened elsewhere (the Calendar
        // tab, an Inbox banner, the CLI) or a token expired in the daemon;
        // config.yaml may have changed behind the shared copy. The agent
        // buttons wait for the harness CLIs Go finds.
        .onAppear {
            appState.refreshConnectionAccounts()
            appState.sharedConfig.reloadUnlessEdited()
        }
        .task(id: appState.connectProviders().map(\.id)) { await appState.refreshConnectReadyProviders() }
        // A company link, code or Connect all (#1887 §3): over whichever
        // Connections page is open. Closing it keeps a running chain.
        .sheet(isPresented: Binding(
            get: { appState.companyConnect?.showsSheet ?? false },
            set: { shown in if !shown { appState.companyConnect?.close() } }
        )) {
            if let flow = appState.companyConnect {
                CompanyConnectSheet(flow: flow)
                    .frame(width: 460)
                    .onExitCommand { flow.close() }
            }
        }
    }
}

/// The service list beside the open service's detail; the existing detail
/// views, unchanged.
struct ConnectionsDetailSplit: View {
    @Environment(AppState.self) private var appState
    let service: ConnectionService

    var body: some View {
        HStack(spacing: 0) {
            // Only a service is ever written: the overview is reached through
            // All Connections, never by deselecting the row.
            List(selection: Binding<ConnectionService?>(
                get: { service },
                set: { if let new = $0 { appState.selectedConnection = new } }
            )) {
                Section("Sources") {
                    ForEach(ConnectionService.sources) { row($0).tag($0) }
                }
                Section("Tools for AI") {
                    ForEach(ConnectionService.aiTools) { row($0).tag($0) }
                }
            }
            // Not .sidebar: outside a NavigationSplitView its vibrancy
            // material bleeds up under the window's toolbar.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: PaneWidth.sideListIdeal)
            Divider()
            Group {
                if service == .companySetup {
                    // The wizard's page brings its own way back (‹ Connections).
                    ScrollView { companySetup }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        if appState.connectionSummary(service).blocked {
                            SourceBlockedNotice()
                        }
                        detail
                    }
                }
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
        case .companySetup: EmptyView() // drawn without the header, above
        }
    }

    private var companySetup: some View {
        CompanySetupPage(model: appState.companySetup, actions: CompanySetupActions(
            back: { appState.selectedConnection = nil },
            openQuickConnections: { appState.openConnections(.quickConnections) },
            showFile: { appState.showCompanySetupFile($0) },
            connectThisMac: appState.connectThisMacAction,
            agent: appState.companySetupAgent
        ))
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

extension View {
    /// Opens the detail's Add sheet when `AppState.connectionAddRequest`
    /// names `service` (the connect assistant's **Set up by hand**), on
    /// appear or later, and clears the request.
    func opensAddSheet(_ service: ConnectionService, open: @escaping () -> Void) -> some View {
        modifier(ConnectionAddRequestModifier(service: service, open: open))
    }
}

private struct ConnectionAddRequestModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    let service: ConnectionService
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: consume)
            .onChange(of: appState.connectionAddRequest) { consume() }
    }

    private func consume() {
        guard appState.connectionAddRequest == service else { return }
        appState.connectionAddRequest = nil
        open()
    }
}
