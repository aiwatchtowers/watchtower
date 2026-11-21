import DesignKit
import SwiftUI
import WatchtowerCore

/// The Connections tab's first screen: a banner per service that needs the
/// owner, the Companies zone (#1887 C3), a card per source, and the
/// assistant's tools. A card opens the service's detail.
struct ConnectionsOverview: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let openService: (ConnectionService) -> Void = { appState.openConnections($0) }
        let agent = appState.connectAgentEntry
        ConnectionsOverviewContent(
            summaries: appState.connectionSummaries,
            companies: CompaniesZone(state: appState.companiesZoneState, model: appState.companiesZone,
                                     connecting: appState.companyConnecting, flowBusy: appState.companyFlowBusy,
                                     actions: appState.companiesZoneActions,
                                     agent: agent.harness(AppState.companyConnectService).map { harness in
                                         (harness, { agent.open(AppState.companyConnectService) })
                                     }),
            onCompanyAction: { appState.performConnectMenuCompanyAction($0) },
            agent: agent,
            onOpen: openService
        )
        // Each time the overview shows: a link, a flow or the wizard may have changed a company file.
        // Not view-bound: leaving for a detail must not cancel the read it then groups by.
        .onAppear { appState.reloadCompanies() }
    }
}

/// The connect assistant's entry points (agent connect spec §7): which
/// harness a connect service's agent button names (nil: no button), and
/// what pressing one does.
struct ConnectAgentEntry {
    var harness: (String) -> ConnectHarness?
    var open: (String) -> Void
}

/// The overview over given summaries; `onOpen` opens a service's detail.
/// `companies` is the zone between the banners and Sources;
/// `onCompanyAction`, when given, ends the Connect… menu with the company
/// entries (company screens spec §2.1); `agent`, when given, adds the
/// connect assistant's buttons.
struct ConnectionsOverviewContent<Companies: View>: View {
    let summaries: [ConnectionSummary]
    let companies: Companies
    var onCompanyAction: ((CompaniesZoneState.Action) -> Void)?
    var agent: ConnectAgentEntry?
    let onOpen: (ConnectionService) -> Void

    private typealias Pres = ConnectAssistantPresentation

    private static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: PaneWidth.gridCardMin), spacing: Spacing.medium, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header
                ForEach(summaries.filter(\.needsAttention)) { summary in
                    ConnectionAttentionBanner(summary: summary, onReconnect: openDetail(summary.service))
                }
                companies
                group("Sources", ConnectionService.sources)
                group("Tools for AI", ConnectionService.aiTools)
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func harness(_ service: ConnectionService) -> ConnectHarness? {
        agent?.harness(service.rawValue)
    }

    private func openAgent(_ service: ConnectionService) -> () -> Void {
        { agent?.open(service.rawValue) }
    }

    private func openDetail(_ service: ConnectionService) -> () -> Void {
        { onOpen(service) }
    }

    private var header: some View {
        HStack {
            Text("Connections")
                .font(.title2.weight(.bold))
            Spacer()
            Menu {
                ForEach(summaries.filter { !$0.blocked }) { summary in
                    Button(summary.service.label) { onOpen(summary.service) }
                }
                agentMenu
                if let onCompanyAction {
                    Divider()
                    ForEach(CompanyConnectionsPresentation.connectMenuCompanyActions, id: \.title) { action in
                        Button(action.title) { onCompanyAction(action) }
                    }
                    if let agent, let harness = agent.harness(AppState.companyConnectService) {
                        Button(Pres.setUpCompanyWith(harness)) { agent.open(AppState.companyConnectService) }
                    }
                }
            } label: {
                Label("Connect…", systemImage: "plus")
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    /// "Connect with Claude ▸" listing the services the assistant can connect (preflight F22).
    @ViewBuilder private var agentMenu: some View {
        let offered = summaries.compactMap { summary in harness(summary.service).map { (summary.service, $0) } }
        if let agent, let first = offered.first {
            Menu(Pres.connectWith(first.1)) {
                ForEach(offered, id: \.0) { service, _ in
                    Button(service.label) { agent.open(service.rawValue) }
                }
            }
        }
    }

    private func group(_ title: String, _ services: [ConnectionService]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HomeZoneTitle(title: title)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Spacing.medium) {
                ForEach(summaries.filter { services.contains($0.service) }) { summary in
                    ConnectionCard(summary: summary, agentHarness: harness(summary.service),
                                   onAgent: openAgent(summary.service), onOpen: openDetail(summary.service))
                }
            }
        }
    }
}

extension ConnectionsOverviewContent where Companies == EmptyView {
    /// The overview without the Companies zone.
    init(summaries: [ConnectionSummary], agent: ConnectAgentEntry? = nil, onOpen: @escaping (ConnectionService) -> Void) {
        self.init(summaries: summaries, companies: EmptyView(), agent: agent, onOpen: onOpen)
    }
}

/// The connect assistant's button (agent connect spec §7): secondary with
/// the sparkles icon, never the screen's prominent one.
struct ConnectAgentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: "sparkles") }
            .buttonStyle(.kitSecondary)
    }
}

/// A service detail's **Connect with <harness>** in its Add an account row
/// (spec §7): nothing when the app state offers no button for the service
/// (blocked, no harness, no driver yet). `disabled` while the detail's own
/// sign-in runs, as its other Add buttons are.
struct ConnectAgentDetailButton: View {
    @Environment(AppState.self) private var appState
    let service: ConnectionService
    var disabled = false

    var body: some View {
        if let harness = appState.connectAssistantButton(for: service.rawValue) {
            ConnectAgentButton(title: ConnectAssistantPresentation.connectWith(harness)) {
                appState.openConnectAssistant(service: service.rawValue)
            }
            .disabled(disabled)
        }
    }
}

/// One service on the overview: name and status mark, account count, one
/// status line. With no account and a harness offered, **Connect with
/// <harness>** and today's **Connect** (which opens the detail) under it.
struct ConnectionCard: View {
    let summary: ConnectionSummary
    var agentHarness: ConnectHarness?
    var onAgent: () -> Void = {}
    let onOpen: () -> Void

    private var agentPair: ConnectHarness? {
        summary.accountCount == 0 && !summary.blocked ? agentHarness : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.regular) {
                        Image(systemName: summary.service.icon)
                            .foregroundStyle(.secondary)
                        Text(summary.service.label)
                            .font(.headline)
                        Spacer()
                        ConnectionStatusMark(summary: summary)
                    }
                    Text(summary.countLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.statusLine)
                        .font(.caption)
                        .foregroundStyle(summary.needsAttention ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding([.top, .horizontal], Spacing.medium)
                // The whole card above the pair opens the detail, its padding too.
                .padding(.bottom, agentPair == nil ? Spacing.medium : Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(summary.service.label): \(summary.countLine), \(summary.statusLine)")
            if let harness = agentPair {
                HStack(spacing: Spacing.regular) {
                    ConnectAgentButton(title: ConnectAssistantPresentation.connectWith(harness), action: onAgent)
                    Button(ConnectAssistantPresentation.connectByHand, action: onOpen)
                        .buttonStyle(.kitQuiet)
                }
                .padding([.horizontal, .bottom], Spacing.medium)
                .padding(.top, Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// "Slack · acme: token expired" with Reconnect, which opens the service.
/// No **Reconnect with <harness>** (spec §7) yet: no connect driver signs
/// an existing account in again — a plain connect would add a new one
/// (Google: the shared client, losing a custom client and its scopes).
struct ConnectionAttentionBanner: View {
    let summary: ConnectionSummary
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning)
            Text(line)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(ConnectAssistantPresentation.reconnectByHand, action: onReconnect)
                .buttonStyle(.kitSecondary)
        }
        .padding(Spacing.medium)
        .card()
    }

    private var line: String {
        guard let problem = summary.problemLine else { return "\(summary.service.label) needs attention" }
        return "\(summary.service.label) · \(problem)"
    }
}
