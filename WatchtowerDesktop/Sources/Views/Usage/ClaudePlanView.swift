import Charts
import SwiftUI
import WatchtowerCore

/// Usage → "Claude plan": the account-wide Claude limits, their history and
/// the projection to the next reset. All text comes from `PlanUsagePresentation`.
struct ClaudePlanView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PlanUsageCenter.menuBarKey) private var showInMenuBar = true
    @State private var series: [String: [PlanUsageSample]] = [:]

    private static let chartKeys = ["session", "weekly_all"]

    var body: some View {
        if let center = appState.planUsageCenter {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(center, now: context.date)
            }
        } else {
            Text("Claude plan limits are not loaded yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ center: PlanUsageCenter, now: Date) -> some View {
        let status = center.status
        let stale = status.map { PlanUsagePresentation.isStale($0, now: now) } ?? true
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(center, now: now)
                if let status {
                    if let banner = PlanUsagePresentation.banner(status, now: now) {
                        Label(banner, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(status.limits) { limit in
                        limitBox(limit, now: now, stale: stale)
                    }
                    if !status.breakdown.isEmpty {
                        breakdownBox(status.breakdown, stale: stale)
                    }
                } else {
                    Text("No plan data yet.").foregroundStyle(.secondary)
                }
                Text("Limits are shared across Claude chats, Cowork and Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show in the menu bar", isOn: $showInMenuBar)
            }
            .padding(20)
        }
        .task(id: status?.fetchedAt) { await loadSeries(center) }
    }

    private func header(_ center: PlanUsageCenter, now: Date) -> some View {
        HStack {
            Text("Claude plan").font(.title2.bold())
            if let plan = center.status?.plan, !plan.isEmpty {
                Text(plan.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            Spacer()
            if let status = center.status, let text = PlanUsagePresentation.updatedText(status, now: now) {
                Text(text).foregroundStyle(.secondary)
            }
            Button("Refresh") { Task { await center.refresh() } }
                .disabled(center.isRefreshing)
        }
    }

    private func limitBox(_ limit: PlanUsageLimit, now: Date, stale: Bool) -> some View {
        let tone = stale ? PlanUsageTone.muted : PlanUsagePresentation.tone(limit)
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(limit.label).fontWeight(.medium)
                    Spacer()
                    Text(PlanUsagePresentation.percentText(limit.percent)).monospacedDigit()
                }
                ProgressView(value: min(100, max(0, limit.percent)), total: 100).tint(color(tone))
                Text(PlanUsagePresentation.resetText(limit, now: now)).font(.caption).foregroundStyle(.secondary)
                Text(PlanUsagePresentation.projectionText(limit, now: now)).font(.caption).foregroundStyle(.secondary)
                if Self.chartKeys.contains(limit.key), let reset = limit.resetsAt,
                   let start = PlanUsagePresentation.windowStart(key: limit.key, resetsAt: reset) {
                    chart(limit, start: start, reset: reset, tone: tone)
                }
            }
            .padding(4)
        }
        .foregroundStyle(stale ? .secondary : .primary)
    }

    private func chart(_ limit: PlanUsageLimit, start: Date, reset: Date, tone: PlanUsageTone) -> some View {
        let points = series[limit.key] ?? []
        let projected = points.last.flatMap { PlanUsagePresentation.projectedEnd(limit, last: $0) }
        return Chart {
            ForEach(points, id: \.takenAt) { sample in
                LineMark(x: .value("Time", sample.takenAt), y: .value("Percent", sample.percent))
                    .foregroundStyle(color(tone))
            }
            if let last = points.last, let end = projected {
                ForEach([(last.takenAt, last.percent), (end.at, end.percent)], id: \.0) { at, percent in
                    LineMark(
                        x: .value("Time", at), y: .value("Percent", percent),
                        series: .value("Series", "projection")
                    )
                        .foregroundStyle(color(tone))
                        .lineStyle(StrokeStyle(dash: [4, 3]))
                }
            }
            RuleMark(x: .value("Reset", reset))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .trailing, overflowResolution: .init(x: .fit)) {
                    Text("Reset").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: start...reset)
        .frame(height: 140)
    }

    private func breakdownBox(_ rows: [PlanUsageBreakdownRow], stale: Bool) -> some View {
        GroupBox("This week by surface") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.label)
                            Spacer()
                            Text(PlanUsagePresentation.percentText(row.percent)).monospacedDigit()
                        }
                        ProgressView(value: min(100, max(0, row.percent)), total: 100)
                            .tint(stale ? .secondary : .accentColor)
                            .controlSize(.small)
                    }
                }
            }
            .padding(4)
        }
        .foregroundStyle(stale ? .secondary : .primary)
    }

    private func loadSeries(_ center: PlanUsageCenter) async {
        var fresh: [String: [PlanUsageSample]] = [:]
        for limit in center.status?.limits ?? [] where Self.chartKeys.contains(limit.key) {
            guard let reset = limit.resetsAt,
                  let start = PlanUsagePresentation.windowStart(key: limit.key, resetsAt: reset) else { continue }
            fresh[limit.key] = await center.samples(key: limit.key, since: start)
        }
        guard !Task.isCancelled else { return }
        series = fresh
    }

    private func color(_ tone: PlanUsageTone) -> Color {
        switch tone {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        case .muted: return .secondary
        }
    }
}
