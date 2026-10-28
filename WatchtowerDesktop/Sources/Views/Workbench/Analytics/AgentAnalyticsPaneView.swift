import SwiftUI
import WatchtowerCore

/// The Analytics pane (#298, spec 2026-10-16-agent-analytics-history Part
/// C): the workbench's agent report from `AgentAnalyticsCenter`, its
/// overview or one session's detail. While on screen the center keeps the
/// overview fresh; the lifecycle hooks sit on a stable ZStack so moving
/// between the overview and a detail neither hides the center nor reruns
/// the overview.
struct AgentAnalyticsPaneView: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    /// Optional: a pane hosted without the app (tests) has none.
    @Environment(AppState.self) private var appState: AppState?

    var body: some View {
        let center = vm.agentAnalytics
        let sessionUUID = vm.analyticsSession[project.id]
        ZStack {
            if let sessionUUID {
                AgentSessionAnalyticsView(
                    snapshot: center?.sessions[sessionUUID],
                    onBack: { vm.analyticsSession[project.id] = nil },
                    actions: actions
                )
                .task(id: sessionUUID) { center?.loadSession(workbench: project.id, uuid: sessionUUID) }
            } else {
                AgentAnalyticsOverviewView(
                    state: .make(overview: center?.overviews[project.id],
                                 enabling: center?.enabling.contains(project.id) ?? false),
                    period: period,
                    actions: actions,
                    coach: vm.coach,
                    workbench: project.id,
                    openAsk: { id in Task { await vm.showAsk(id, projectID: project.id) } },
                    openTerminalSession: { id in Task { await vm.showSession(id: id) } }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            center?.show(workbench: project.id, period: period.wrappedValue)
            syncCoach()
        }
        .onDisappear {
            center?.hide(workbench: project.id)
            vm.coach?.hide(workbench: project.id)
        }
        .onChange(of: period.wrappedValue) { _, new in
            center?.show(workbench: project.id, period: new)
            syncCoach()
        }
        .onChange(of: analyticsOn) { _, _ in syncCoach() }
    }

    /// Analytics is on for the workbench (the coach reads only then).
    private var analyticsOn: Bool { vm.agentAnalytics?.overviews[project.id]?.value?.enabled == true }

    private func syncCoach() {
        if analyticsOn {
            vm.coach?.show(workbench: project.id, period: period.wrappedValue)
        } else {
            vm.coach?.hide(workbench: project.id)
        }
    }

    private var period: Binding<AgentAnalyticsCenter.Period> {
        Binding(
            get: { vm.analyticsPeriod[project.id] ?? .week },
            set: { vm.analyticsPeriod[project.id] = $0 }
        )
    }

    private var actions: AgentAnalyticsActions {
        let center = vm.agentAnalytics
        return AgentAnalyticsActions(
            turnOn: { Task { await center?.turnOn(workbench: project.id) } },
            openSession: { vm.analyticsSession[project.id] = $0 },
            openTarget: { vm.showTargetOnBoard($0, projectID: project.id) },
            openFile: { path in
                let root = vm.codeRoot(sessionID: nil, project: project)
                Task { await vm.openFile(path, root: root, preview: false) }
            },
            openAsks: { Task { await vm.showWaitingForYou(projectID: project.id) } },
            discuss: { [appState] in appState?.openHelpChat(prefill: $0) },
            asksWaiting: !vm.asks.stack(projectID: project.id).asks.isEmpty
        )
    }
}

/// What the pane's links do; the pane wires them to the page.
struct AgentAnalyticsActions {
    /// Turn On: `agents enable` for the workbench.
    let turnOn: () -> Void
    /// A session uuid: its detail inside the pane.
    let openSession: (String) -> Void
    /// A target id: the Board with that target's card open.
    let openTarget: (Int64) -> Void
    /// A path relative to the workbench folder: the file in the Files pane.
    let openFile: (String) -> Void
    /// The workbench's Waiting for you stack.
    let openAsks: () -> Void
    /// Discuss in Chat: the chat popup with this text in its composer.
    let discuss: (String) -> Void
    /// Whether an ask of the workbench waits now (Open Waiting for You is
    /// off without one).
    let asksWaiting: Bool
}

/// What the overview shows.
enum AgentAnalyticsPaneState: Equatable {
    /// The first run has not answered yet.
    case loading
    /// The first run failed: only its error line.
    case failed(String)
    /// Analytics is off for the workbench; `enabling` while Turn On runs,
    /// `error` when it (or the reload after it) failed.
    case off(enabling: Bool, error: String?)
    /// A report; `staleError` is the error line of the run after it.
    case overview(AgentReportOverview, staleError: String?)

    static func make(overview: SessionReportCenter.Snapshot<AgentReportOverview>?, enabling: Bool) -> Self {
        guard let value = overview?.value else {
            if enabling { return .off(enabling: true, error: nil) }
            return overview?.error.map(Self.failed) ?? .loading
        }
        if !value.enabled { return .off(enabling: enabling, error: enabling ? nil : overview?.error) }
        return .overview(value, staleError: overview?.error)
    }
}
