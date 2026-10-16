import Charts
import SwiftUI
import WatchtowerCore

/// One session's analytics inside the pane: its breakdown, the subagent
/// figures, a timeline of the main agent and each subagent, its hints and
/// commands. Back returns to the overview.
struct AgentSessionAnalyticsView: View {
    let snapshot: SessionReportCenter.Snapshot<AgentSessionDetail>?
    let onBack: () -> Void
    let actions: AgentAnalyticsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to the overview")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if let detail = snapshot?.value {
                ScrollView {
                    content(detail, staleError: snapshot?.error)
                        .frame(maxWidth: 900, alignment: .leading)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
            } else if let error = snapshot?.error {
                VStack(spacing: 6) {
                    Label("Could not load the session", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading the session…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(_ detail: AgentSessionDetail, staleError: String?) -> some View {
        let session = detail.session
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Session \(String(session.uuid.prefix(8)))").font(.headline)
                Text(summary(detail)).font(.callout).foregroundStyle(.secondary)
                if let staleError {
                    Label(staleError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("The last refresh failed; these numbers are from an earlier run.")
                }
            }
            if session.oldFormat {
                Text("An older session — its time was not analysed.").foregroundStyle(.secondary)
            } else {
                AgentAnalyticsSection(title: "Where the time went") { AgentTimeBreakdownView(time: detail.time) }
                AgentAnalyticsSection(title: "Subagents") {
                    Text(Self.subagentsLine(detail.subagents)).font(.callout)
                }
                AgentAnalyticsSection(title: "Timeline") { AgentSessionTimelineView(lanes: detail.lanes) }
            }
            if !detail.hints.isEmpty {
                AgentAnalyticsSection(title: "What would save the most") {
                    AgentAnalyticsHintsView(hints: detail.hints, actions: actions)
                }
            }
            if !detail.commands.isEmpty {
                AgentAnalyticsSection(title: "Commands") { AgentAnalyticsCommandsTable(commands: detail.commands) }
            }
        }
    }

    private func summary(_ detail: AgentSessionDetail) -> String {
        let session = detail.session
        var parts = [AgentAnalyticsFormat.moment(session.startedAt)]
        if !session.oldFormat { parts.append("active \(AgentAnalyticsFormat.duration(detail.time.activeMS))") }
        parts.append(AgentAnalyticsFormat.cost(session.costUSD))
        if !session.model.isEmpty { parts.append(session.model) }
        if !session.branch.isEmpty { parts.append(session.branch) }
        return parts.joined(separator: " · ")
    }

    /// "4 subagents (3 foreground, 1 background) · 1.2 at once on average ·
    /// peak 2 · 2 one after another · main agent blocked 2m".
    static func subagentsLine(_ subagents: AgentSubagents) -> String {
        guard subagents.count >= 1 else { return "No subagents" }
        return [
            "\(subagents.count) subagents (\(subagents.foreground) foreground, \(subagents.background) background)",
            "\(String(format: "%.1f", subagents.avgParallel)) at once on average",
            "peak \(subagents.peak)",
            "\(subagents.serial) one after another",
            "main agent blocked \(AgentAnalyticsFormat.duration(subagents.blockedMS))"
        ].joined(separator: " · ")
    }
}

/// The session timeline: one lane for the main agent and one per subagent
/// on a shared time axis, segments coloured by category. Hovering a
/// segment names it above the lanes.
struct AgentSessionTimelineView: View {
    private struct Span: Identifiable {
        let id: Int
        let start: Date
        let end: Date
        let segment: AgentSegment
    }

    let lanes: [AgentLane]
    @State private var hovered: String?

    static func laneTitle(_ lane: AgentLane) -> String {
        if lane.agentID.isEmpty { return "Main agent" }
        let type = lane.subagentType.isEmpty ? "subagent" : lane.subagentType
        return lane.background ? "\(type) · background" : type
    }

    /// "Tools · build & test · make test · 3m", "Model · 30s".
    static func describe(_ segment: AgentSegment) -> String {
        var parts = [segment.timeCategory?.title ?? segment.category]
        if !segment.toolClass.isEmpty { parts.append(AgentToolClass.title(segment.toolClass)) }
        if !segment.verb.isEmpty { parts.append(segment.verb) }
        if let start = AgentAnalyticsFormat.reportDate(segment.start), let end = AgentAnalyticsFormat.reportDate(segment.end) {
            parts.append(AgentAnalyticsFormat.duration(Int64(end.timeIntervalSince(start) * 1000)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let spans = lanes.map(Self.spans)
        let domain = Self.domain(spans.flatMap { $0 })
        VStack(alignment: .leading, spacing: 4) {
            Text(hovered ?? "Point at a segment for its details.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                HStack(spacing: 8) {
                    Text(Self.laneTitle(lane))
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                    laneChart(spans[index], title: Self.laneTitle(lane), domain: domain)
                }
            }
            if let domain {
                HStack {
                    Spacer().frame(width: 188)
                    Text(domain.lowerBound.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text(domain.upperBound.formatted(date: .omitted, time: .shortened))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func laneChart(_ spans: [Span], title: String, domain: ClosedRange<Date>?) -> some View {
        AgentChartHost {
            laneChartContent(spans, title: title, domain: domain)
        }
        .frame(height: 14)
    }

    private func laneChartContent(_ spans: [Span], title: String, domain: ClosedRange<Date>?) -> some View {
        Chart(spans) { span in
            BarMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end), y: .value("Lane", title))
                .foregroundStyle(span.segment.timeCategory?.color ?? .secondary)
                .accessibilityLabel(Self.describe(span.segment))
        }
        .chartXScale(domain: domain ?? Date()...Date().addingTimeInterval(1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case let .active(location) = phase,
                              let plot = proxy.plotFrame,
                              let at = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self),
                              let span = spans.first(where: { $0.start <= at && at < $0.end })
                        else {
                            hovered = nil
                            return
                        }
                        hovered = "\(title) — \(Self.describe(span.segment))"
                    }
            }
        }
    }

    private static func spans(_ lane: AgentLane) -> [Span] {
        lane.segments.enumerated().compactMap { index, segment in
            guard let start = AgentAnalyticsFormat.reportDate(segment.start),
                  let end = AgentAnalyticsFormat.reportDate(segment.end), end > start else { return nil }
            return Span(id: index, start: start, end: end, segment: segment)
        }
    }

    private static func domain(_ spans: [Span]) -> ClosedRange<Date>? {
        guard let start = spans.map(\.start).min(), let end = spans.map(\.end).max(), end > start else { return nil }
        return start...end
    }
}
