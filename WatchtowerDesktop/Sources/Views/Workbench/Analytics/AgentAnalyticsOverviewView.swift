import SwiftUI
import WatchtowerCore

/// The overview: header, tiles, the main thing (the first hint), the
/// Context, Skills and Trouble blocks, the other hints, then the collapsed
/// Time section (where the time went, tasks, sessions, commands, models).
struct AgentAnalyticsOverviewView: View {
    let state: AgentAnalyticsPaneState
    @Binding var period: AgentAnalyticsCenter.Period
    let actions: AgentAnalyticsActions
    /// The coach sections (nil: a pane hosted without the coach).
    var coach: CoachCenter?
    var workbench: Int64 = 0
    /// An ask link of a proposal: the ask's drawer.
    var openAsk: (Int64) -> Void = { _ in }
    /// A terminal session link of a proposal.
    var openTerminalSession: (Int64) -> Void = { _ in }

    private static let statisticsID = "statistics"

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Loading analytics…").controlSize(.small)
        case let .failed(error):
            VStack(spacing: Spacing.compact) {
                Label("Could not load analytics", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).foregroundStyle(.secondary)
            }
            .padding(24)
        case let .off(enabling, error):
            offView(enabling: enabling, error: error)
        case let .overview(overview, staleError):
            ScrollViewReader { proxy in
                ScrollView {
                    content(overview, staleError: staleError) {
                        withAnimation(Motion.panel) { proxy.scrollTo(Self.statisticsID, anchor: .top) }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(Spacing.large)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func offView(enabling: Bool, error: String?) -> some View {
        VStack(spacing: Spacing.cozy) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Agent analytics is off").font(.headline)
            Text("Turn it on to see where this folder's agent sessions spend their time and money. "
                + "It reads the history of Claude Code sessions in this folder; no transcript text is kept.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if enabling {
                ProgressView("Turning on…").controlSize(.small)
            } else {
                Button("Turn On", action: actions.turnOn).buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(24)
    }

    private func content(
        _ overview: AgentReportOverview, staleError: String?, scrollToStatistics: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            if let state = overview.importState, let line = AgentAnalyticsFormat.importLine(state) {
                if AgentAnalyticsFormat.isImportWarning(state) {
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("The history import waits for a one-time move of the analytics rows out of watchtower.db.")
                } else {
                    Label(line, systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The daemon imports this folder's session history in the background; the numbers grow as it goes.")
                }
            }
            header(overview)
            if let staleError {
                Label(staleError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The last refresh failed; these numbers are from an earlier run.")
            }
            if let coach {
                CoachSectionsView(
                    coach: coach, workbench: workbench,
                    actions: CoachActions(openAsk: openAsk, openTerminalSession: openTerminalSession,
                                          scrollToStatistics: scrollToStatistics)
                )
                SectionHeader(title: "Statistics", systemImage: "chart.bar").id(Self.statisticsID)
            }
            tiles(overview)
            if let first = overview.hints.first {
                AgentAnalyticsMainThingCard(hint: first, actions: actions)
            }
            AgentAnalyticsContextView(context: overview.context, actions: actions)
            AgentAnalyticsSkillsView(skills: overview.skills)
            AgentAnalyticsTroubleView(trouble: overview.trouble, actions: actions)
            if overview.hints.count > 1 {
                section("What else would save") {
                    AgentAnalyticsCappedHints(hints: Array(overview.hints.dropFirst()), actions: actions)
                }
            }
            DisclosureGroup {
                time(overview).padding(.top, Spacing.regular)
            } label: {
                Text("Time")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// The collapsed Time section: where the time went, then the tasks,
    /// sessions, commands and models.
    private func time(_ overview: AgentReportOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            section("Where the time went") { AgentTimeBreakdownView(time: overview.time) }
            if overview.oldFormatSessions > 0 {
                Text("Older sessions — time not analysed: \(overview.oldFormatSessions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !overview.tasks.isEmpty {
                section("Tasks") {
                    AgentAnalyticsTopRows(rows: overview.tasks, shown: 10) { rows in
                        AgentAnalyticsTasksTable(tasks: rows, actions: actions)
                    }
                    if let more = overview.tasksMore, more > 0 {
                        Text("\(more) more \(more == 1 ? "task" : "tasks") not shown — they cost less")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            section("Sessions") {
                if overview.sessions.isEmpty {
                    Text("No agent sessions in this period.").foregroundStyle(.secondary)
                } else {
                    AgentAnalyticsTopRows(rows: overview.sessions, shown: 5) { rows in
                        AgentAnalyticsSessionsTable(sessions: rows, actions: actions)
                    }
                }
            }
            if !overview.commands.isEmpty {
                section("Commands") { AgentAnalyticsCommandsTable(commands: overview.commands) }
            }
            section("Tokens & cost") { AgentAnalyticsModelsTable(models: overview.models, tokens: overview.totals.tokens) }
        }
    }

    private func header(_ overview: AgentReportOverview) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(AgentAnalyticsFormat.periodLabel(overview)).font(.headline)
            if let previous = AgentAnalyticsFormat.previousPeriodLabel(overview) {
                Text("against \(previous)").font(.caption).foregroundStyle(.secondary)
            }
            if AgentAnalyticsFormat.period(of: overview) != period {
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.regular)
            KitSegmentedPicker(title: "Period", selection: $period, segments: [
                KitSegment(value: AgentAnalyticsCenter.Period.day, title: "1 day"),
                KitSegment(value: AgentAnalyticsCenter.Period.week, title: "7 days"),
                KitSegment(value: AgentAnalyticsCenter.Period.month, title: "30 days")
            ])
            Circle()
                .fill(Tone.success)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                .help("Agent analytics is on for this workbench")
                .accessibilityLabel("Analytics on")
            Button("Discuss in Chat") { actions.discuss(AgentAnalyticsFormat.discussText(overview)) }
                .buttonStyle(.kitSecondary)
                .help("Open the chat with this report's top findings in the composer")
        }
        .controlSize(.small)
    }

    private func tiles(_ overview: AgentReportOverview) -> some View {
        let totals = overview.totals
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: 24) {
                tile("Cost", AgentAnalyticsFormat.cost(totals.costUSD))
                tile("Sessions", "\(totals.sessions)")
                tile("Active", AgentAnalyticsFormat.duration(totals.activeMS))
                tile("Cache hit", AgentAnalyticsFormat.cacheHit(totals.tokens))
                    .help("Input tokens read from the cache, of all input tokens")
            }
            Text(AgentAnalyticsFormat.subagentsLine(overview.subagents))
                .font(.callout)
            if totals.costEstimatedCalls > 0 {
                Text("\(totals.costEstimatedCalls) \(totals.costEstimatedCalls == 1 ? "call" : "calls") priced by estimate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        AgentAnalyticsSection(title: title, content: content)
    }
}

/// A titled block of the pane.
struct AgentAnalyticsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
