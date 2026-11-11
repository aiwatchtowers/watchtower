import SwiftUI
import WatchtowerCore

/// The Analytics overview's header (spec 2026-11-03 §3, §4.4): the period's
/// labels, then the agent filter, the period picker, the state dot and
/// **Tune**, the toggle of the tuning side panel. One row while the pane is
/// wide; the controls wrap under the labels when the open panel leaves the
/// pane narrow.
struct AgentAnalyticsHeaderView: View {
    let overview: AgentReportOverview
    @Binding var period: AgentAnalyticsCenter.Period
    @Binding var agent: AgentAnalyticsCenter.Agent
    let tuneOn: Bool
    let showsAgentPicker: Bool
    let onTune: () -> Void
    @State private var tuneHovered = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.regular) {
                labels
                Spacer(minLength: Spacing.regular)
                agentPicker
                periodControls
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                labels
                HStack(spacing: Spacing.regular) {
                    agentPicker
                    periodControls
                }
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                labels
                agentPicker
                periodControls
            }
        }
        .controlSize(.small)
    }

    private var labels: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(AgentAnalyticsFormat.periodLabel(overview)).font(.headline)
            if let previous = AgentAnalyticsFormat.previousPeriodLabel(overview) {
                Text("against \(previous)").font(.caption).foregroundStyle(.secondary)
            }
            if AgentAnalyticsFormat.period(of: overview) != period
                || AgentAnalyticsFormat.agent(of: overview) != agent {
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var agentPicker: some View {
        if showsAgentPicker {
            KitSegmentedPicker(title: "Agent", selection: $agent, segments: AgentAnalyticsCenter.Agent.allCases.map {
                KitSegment(value: $0, title: AgentAnalyticsFormat.agentTitle($0))
            })
            .fixedSize()
            .help(AgentAnalyticsFormat.agentHelp)
        }
    }

    private var periodControls: some View {
        HStack(alignment: .center, spacing: Spacing.regular) {
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
            Toggle(isOn: Binding(get: { tuneOn }, set: { _ in onTune() })) {
                Label(TuningChatTexts.tune, systemImage: TuningChatTexts.tuneIcon)
            }
            .toggleStyle(SegmentedToggleStyle(isHovered: tuneHovered) { tuneHovered = $0 })
            .segmentCapsule()
            .help(TuningChatTexts.tuneHelp)
        }
        .fixedSize()
    }
}
