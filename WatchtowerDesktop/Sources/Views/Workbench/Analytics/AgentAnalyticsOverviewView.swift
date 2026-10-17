import SwiftUI
import WatchtowerCore

/// The overview: header, tiles, where the time went, hints, then the
/// tasks, sessions, commands and models.
struct AgentAnalyticsOverviewView: View {
    let state: AgentAnalyticsPaneState
    @Binding var period: AgentAnalyticsCenter.Period
    let actions: AgentAnalyticsActions

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Loading analytics…").controlSize(.small)
        case let .failed(error):
            VStack(spacing: 6) {
                Label("Could not load analytics", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).foregroundStyle(.secondary)
            }
            .padding(24)
        case let .off(enabling, error):
            offView(enabling: enabling, error: error)
        case let .overview(overview, staleError):
            ScrollView {
                content(overview, staleError: staleError)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func offView(enabling: Bool, error: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Agent analytics is off").font(.headline)
            Text("Turn it on to see where this folder's agent sessions spend their time and money. "
                + "It reads the history of Claude Code sessions in this folder; no transcript text is kept.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if enabling {
                ProgressView("Loading the history…").controlSize(.small)
            } else {
                Button("Turn On", action: actions.turnOn).buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(24)
    }

    private func content(_ overview: AgentReportOverview, staleError: String?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            header(overview)
            if let staleError {
                Label(staleError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The last refresh failed; these numbers are from an earlier run.")
            }
            tiles(overview)
            section("Where the time went") { AgentTimeBreakdownView(time: overview.time) }
            if !overview.hints.isEmpty {
                section("What would save the most") { AgentAnalyticsHintsView(hints: overview.hints, actions: actions) }
            }
            if overview.oldFormatSessions > 0 {
                Text("Older sessions — time not analysed: \(overview.oldFormatSessions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !overview.tasks.isEmpty {
                section("Tasks") { AgentAnalyticsTasksTable(tasks: overview.tasks, actions: actions) }
            }
            section("Sessions") {
                if overview.sessions.isEmpty {
                    Text("No agent sessions in this period.").foregroundStyle(.secondary)
                } else {
                    AgentAnalyticsSessionsTable(sessions: overview.sessions, actions: actions)
                }
            }
            if !overview.commands.isEmpty {
                section("Commands") { AgentAnalyticsCommandsTable(commands: overview.commands) }
            }
            section("Tokens & cost") { AgentAnalyticsModelsTable(models: overview.models, tokens: overview.totals.tokens) }
        }
    }

    private func header(_ overview: AgentReportOverview) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(AgentAnalyticsFormat.periodLabel(overview)).font(.headline)
            if AgentAnalyticsFormat.period(of: overview) != period {
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("Period", selection: $period) {
                Text("7 days").tag(AgentAnalyticsCenter.Period.week)
                Text("30 days").tag(AgentAnalyticsCenter.Period.month)
                Text("All").tag(AgentAnalyticsCenter.Period.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Label("On", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.green)
                .help("Agent analytics is on for this workbench")
        }
    }

    private func tiles(_ overview: AgentReportOverview) -> some View {
        let totals = overview.totals
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 24) {
                tile("Active", AgentAnalyticsFormat.duration(totals.activeMS))
                tile("Away", AgentAnalyticsFormat.duration(totals.awayMS))
                tile("Cost", AgentAnalyticsFormat.cost(totals.costUSD))
                tile("Sessions", "\(totals.sessions)")
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
        VStack(alignment: .leading, spacing: 2) {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
