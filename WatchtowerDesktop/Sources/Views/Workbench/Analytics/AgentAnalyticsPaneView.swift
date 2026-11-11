import SwiftUI
import WatchtowerCore

/// The Analytics pane (#298, spec 2026-10-16-agent-analytics-history Part
/// C): the workbench's agent report from `AgentAnalyticsCenter`, its
/// overview or one session's detail, and the tuning side panel (**Tune**,
/// #1517, spec 2026-11-03 §3) beside it. While on screen the center keeps
/// the overview fresh; the lifecycle hooks sit on a stable ZStack so moving
/// between the overview and a detail neither hides the center nor reruns
/// the overview.
struct AgentAnalyticsPaneView: View {
    /// The tuning panel's width: 460 until dragged, 360–720, remembered.
    static let tuningWidth = PanelSplitWidth(key: "analytics.tuningPanelWidth", range: 360...720, ideal: 460)

    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    /// Builds the tuning panel's chat; nil = `AppState.makeTuningChat`.
    var makeTuningChat: TuningPanelHost.MakeChat?
    /// Optional: a pane hosted without the app (tests) has none.
    @Environment(AppState.self) private var appState: AppState?

    var body: some View {
        PanelSplit(isPanelShown: tuningShown, width: Self.tuningWidth) {
            content
        } panel: {
            TuningPanelHost(
                workbenchID: project.id,
                makeChat: makeTuningChat ?? appStateMakeChat,
                coach: vm.coach,
                inputs: tuningInputs,
                actions: coachActions,
                onClose: closeTuning,
                onOpenSettings: { [appState] in
                    appState?.settingsTab = .system
                    appState?.openSettingsWindow?()
                },
                onShowAccepted: { _ in vm.analyticsScroll[project.id] = CoachSectionsView.acceptedID }
            )
            .panelBackground()
            .onExitCommand(perform: closeTuning)
        }
    }

    private var content: some View {
        let center = vm.agentAnalytics
        let sessionUUID = vm.analyticsSession[project.id]
        return ZStack {
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
                    agent: agent,
                    actions: actions,
                    coach: vm.coach,
                    workbench: project.id,
                    openAsk: { id in Task { await vm.showAsk(id, projectID: project.id) } },
                    openTerminalSession: { id in Task { await vm.showSession(id: id) } },
                    scrollRequest: scrollRequest
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            center?.show(workbench: project.id, period: period.wrappedValue, agent: agent.wrappedValue)
            syncCoach()
            if analyticsOff { vm.tuningOpen.remove(project.id) }
        }
        .onDisappear {
            center?.hide(workbench: project.id)
            vm.coach?.hide(workbench: project.id)
        }
        .onChange(of: query) { _, new in
            center?.show(workbench: project.id, period: new.period, agent: new.agent)
            syncCoach()
        }
        .onChange(of: analyticsOn) { _, _ in syncCoach() }
        .onChange(of: analyticsOff) { _, off in
            if off { vm.tuningOpen.remove(project.id) }
        }
    }

    /// Analytics is on for the workbench (the coach reads only then).
    private var analyticsOn: Bool { vm.agentAnalytics?.overviews[project.id]?.value?.enabled == true }

    /// The report says analytics is off: the panel is not offered (§4.4).
    private var analyticsOff: Bool { vm.agentAnalytics?.overviews[project.id]?.value?.enabled == false }

    private var tuningShown: Bool { vm.tuningOpen.contains(project.id) && !analyticsOff }

    private func closeTuning() { vm.tuningOpen.remove(project.id) }

    private func syncCoach() {
        if analyticsOn {
            vm.coach?.show(workbench: project.id, period: period.wrappedValue, agent: agent.wrappedValue)
        } else {
            vm.coach?.hide(workbench: project.id)
        }
    }

    /// The chat reads the pane's period at each turn, so every panel of the
    /// workbench follows the same Analytics period.
    private var appStateMakeChat: TuningPanelHost.MakeChat {
        { [appState, vm] workbenchID in
            try await appState?.makeTuningChat(workbenchID: workbenchID) { vm.analyticsPeriod[workbenchID] ?? .week }
        }
    }

    private var tuningInputs: TuningPanelInputs {
        .make(overview: vm.agentAnalytics?.overviews[project.id]?.value,
              status: vm.coach?.status[project.id]?.value,
              query: query)
    }

    private var coachActions: CoachActions {
        CoachActions(
            openAsk: { id in Task { await vm.showAsk(id, projectID: project.id) } },
            openTerminalSession: { id in Task { await vm.showSession(id: id) } },
            scrollToStatistics: { vm.analyticsScroll[project.id] = AgentAnalyticsOverviewView.statisticsID }
        )
    }

    private var scrollRequest: Binding<String?> {
        Binding(
            get: { vm.analyticsScroll[project.id] },
            set: { vm.analyticsScroll[project.id] = $0 }
        )
    }

    private var period: Binding<AgentAnalyticsCenter.Period> {
        Binding(
            get: { vm.analyticsPeriod[project.id] ?? .week },
            set: { vm.analyticsPeriod[project.id] = $0 }
        )
    }

    private var agent: Binding<AgentAnalyticsCenter.Agent> {
        Binding(
            get: { vm.analyticsAgent[project.id] ?? .all },
            set: { vm.analyticsAgent[project.id] = $0 == .all ? nil : $0 }
        )
    }

    private var query: AgentAnalyticsCenter.Query {
        AgentAnalyticsCenter.Query(period: period.wrappedValue, agent: agent.wrappedValue)
    }

    private var actions: AgentAnalyticsActions {
        let center = vm.agentAnalytics
        let id = project.id
        return AgentAnalyticsActions(
            turnOn: { Task { await center?.turnOn(workbench: id) } },
            openSession: { vm.analyticsSession[id] = $0 },
            openTarget: { vm.showTargetOnBoard($0, projectID: id) },
            openFile: { path in
                let root = vm.codeRoot(sessionID: nil, project: project)
                Task { await vm.openFile(path, root: root, preview: false) }
            },
            openAsks: { Task { await vm.showWaitingForYou(projectID: id) } },
            tune: {
                if vm.tuningOpen.contains(id) { vm.tuningOpen.remove(id) } else { vm.tuningOpen.insert(id) }
            },
            tuneOn: vm.tuningOpen.contains(id),
            retry: { center?.retry(workbench: id) },
            asksWaiting: !vm.asks.stack(projectID: id).asks.isEmpty
        )
    }
}

/// What the tuning panel shows from the pane's report and the coach's
/// status: the figures line, the starters and whether the report is still
/// loading for the pane's period and agent.
struct TuningPanelInputs: Equatable {
    var figures: TuningChatTexts.Figures?
    var starters: [ChatStarterPrompt]
    var loading: Bool

    static func make(
        overview: AgentReportOverview?,
        status: CoachStatus?,
        query: AgentAnalyticsCenter.Query
    ) -> Self {
        guard let overview, AgentAnalyticsFormat.period(of: overview) == query.period,
              AgentAnalyticsFormat.agent(of: overview) == query.agent else {
            return Self(figures: nil, starters: [], loading: true)
        }
        let cost = status?.metrics.taskCostUSD
        let perTask = cost?.known == true ? cost?.value : nil
        let previous = perTask == nil ? nil : cost?.previous
        let figures = TuningChatTexts.Figures(
            days: query.period.rawValue, sessions: overview.totals.sessions,
            tasks: overview.tasks.count + (overview.tasksMore ?? 0), costUSD: overview.totals.costUSD,
            perTaskUSD: perTask, previousPerTaskUSD: previous
        )
        let grew = perTask.flatMap { value in previous.map { value > $0 } } ?? false
        let starters = TuningChatTexts.starters(.init(costPerTaskGrew: grew, topHintFinding: overview.hints.first?.finding))
        return Self(figures: figures, starters: starters, loading: false)
    }
}

/// The tuning panel's host: builds the workbench's `TuningChat` once (the
/// engine lives in the embedded-chat center, so a turn outlives the panel)
/// and closes its view of it when the panel goes.
struct TuningPanelHost: View {
    typealias MakeChat = @MainActor (Int64) async throws -> TuningChat?

    let workbenchID: Int64
    let makeChat: MakeChat
    let coach: CoachCenter?
    let inputs: TuningPanelInputs
    let actions: CoachActions
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onShowAccepted: (Int64) -> Void
    @State private var chat: TuningChat?
    @State private var error: String?

    var body: some View {
        Group {
            if let chat {
                TuningPanelView(chat: chat, coach: coach, figures: inputs.figures, starters: inputs.starters,
                                loading: inputs.loading, actions: actions, onClose: onClose,
                                onOpenSettings: onOpenSettings, onShowAccepted: onShowAccepted)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: workbenchID) {
            chat?.close()
            chat = nil
            error = nil
            do {
                chat = try await makeChat(workbenchID)
            } catch {
                self.error = TuningChatTexts.newChatFailed(error.localizedDescription)
            }
        }
        .onDisappear {
            chat?.close()
            chat = nil
        }
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
    /// **Tune**: opens or closes the tuning side panel.
    let tune: () -> Void
    /// The tuning panel is open (Tune has the selected look).
    var tuneOn = false
    /// Retry on the report's error line: the overview runs once more.
    var retry: () -> Void = {}
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
