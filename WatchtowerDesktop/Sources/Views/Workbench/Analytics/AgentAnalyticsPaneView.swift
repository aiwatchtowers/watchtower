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
                    actions: actions
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { center?.show(workbench: project.id, period: period.wrappedValue) }
        .onDisappear { center?.hide(workbench: project.id) }
        .onChange(of: period.wrappedValue) { _, new in center?.show(workbench: project.id, period: new) }
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
            openTarget: { vm.showTargetOnBoard($0, projectID: project.id) }
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

/// The pane's strings.
enum AgentAnalyticsFormat {
    /// "14h 20m", "31h", "27m", "45s".
    static func duration(_ ms: Int64) -> String {
        let seconds = max(ms, 0) / 1000
        let hours = seconds / 3600, minutes = seconds % 3600 / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func cost(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int((part / whole * 100).rounded()))%"
    }

    static func subagentsLine(_ subagents: AgentSubagents) -> String {
        guard subagents.count >= 1 else { return "Subagents: none" }
        return "Subagents: \(String(format: "%.1f", subagents.avgParallel)) at once on average · peak \(subagents.peak)"
    }

    /// The period the report covers, from its own `since`/`until`; nil
    /// when it matches none of the picker's.
    static func period(of overview: AgentReportOverview) -> AgentAnalyticsCenter.Period? {
        if overview.since.isEmpty { return .all }
        guard let since = date(overview.since), let until = date(overview.until) else { return nil }
        return AgentAnalyticsCenter.Period(rawValue: Int((until.timeIntervalSince(since) / 86400).rounded()))
    }

    /// "Oct 1 – Oct 8", or "All history to Oct 8".
    static func periodLabel(_ overview: AgentReportOverview, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        let until = date(overview.until).map(formatter.string(from:)) ?? overview.until
        guard !overview.since.isEmpty else { return "All history to \(until)" }
        let since = date(overview.since).map(formatter.string(from:)) ?? overview.since
        return "\(since) – \(until)"
    }

    /// "Oct 1, 10:00" in local time.
    static func moment(_ raw: String) -> String {
        guard let value = date(raw) else { return raw }
        return value.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The report's RFC 3339 times, with or without fractional seconds.
    static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
