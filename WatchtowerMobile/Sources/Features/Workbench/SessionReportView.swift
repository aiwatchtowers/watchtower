import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// A session's report and timeline (spec §4.8, §5.3), reached from the
/// workchat's actions menu "Report and timeline": the header (title,
/// target, branch, agent and age, the Mac's state), the report's progress
/// and summary, and the timeline. Opening it asks the Mac for a fresh
/// report.
struct SessionReportView: View {
    let replica: WorkbenchReplicaModel
    @State private var viewModel: SessionDetailViewModel

    init(replica: WorkbenchReplicaModel, sessionID: Int64, store: ReplicaStore, requester: SessionReportRequester) {
        self.replica = replica
        _viewModel = State(initialValue: SessionDetailViewModel(sessionID: sessionID, store: store, requester: requester))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let detail = SessionDetailModel(
                sessionID: viewModel.sessionID,
                snapshot: replica.snapshot,
                report: viewModel.report,
                timeline: viewModel.timeline,
                now: context.date
            ) {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "terminal",
                    description: Text("It was removed on your Mac.")
                )
            }
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.opened() }
    }

    private func content(_ detail: SessionDetailModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header(detail)
                if viewModel.waitingForKeys {
                    Text("Unlock this iPhone to see the latest report.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let report = detail.report {
                    SessionReportCard(report: report)
                }
                timeline(detail)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.regular)
        }
        .background(Color(.systemBackground))
    }

    private func header(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(detail.title)
                .font(TypeScale.pageTitle)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Spacing.compact) {
                SessionDot(tone: detail.state.tone, isRing: detail.state.isRing)
                Text(detail.state.caption)
            }
            .font(.subheadline)
            .foregroundStyle(detail.state.tone.color)
            .accessibilityElement(children: .combine)
            FlowRow { chips(detail) }
        }
    }

    @ViewBuilder
    private func chips(_ detail: SessionDetailModel) -> some View {
        if let target = detail.target {
            NavigationLink(value: BoardTargetRoute(id: target.id)) {
                Pill(text: target.label, tone: .accent)
                    .frame(minHeight: PhoneMetrics.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Target \(target.label)")
        }
        if let branch = detail.branch {
            Pill(text: branch, style: .neutral, monospaced: true)
                .frame(minHeight: PhoneMetrics.minTouch)
                .accessibilityLabel("Branch \(branch)")
        }
        Pill(text: detail.agentLine, style: .neutral).frame(minHeight: PhoneMetrics.minTouch)
    }

    private func timeline(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Timeline")
                .font(TypeScale.sectionHeader)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if let empty = detail.timelineEmptyText {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: PhoneMetrics.minTouch, alignment: .leading)
            }
            ForEach(detail.timeline) { row in
                if let target = row.targetID {
                    NavigationLink(value: BoardTargetRoute(id: target)) {
                        MilestoneRowView(row: row, opens: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    MilestoneRowView(row: row, opens: false)
                }
            }
            if let more = detail.timelineMoreText {
                Text(more)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The report: "REPORT · 2 / 7 targets", the segments, the summary and PRs.
private struct SessionReportCard: View {
    let report: SessionReportSection

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack {
                Text("Report")
                    .font(TypeScale.sectionHeader)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(report.progressLabel)
                    .font(TypeScale.time)
                    .foregroundStyle(.secondary)
            }
            if !report.segments.isEmpty {
                segments
            }
            ForEach(report.summary, id: \.self) { line in
                Text(line).font(TypeScale.rowTitle)
            }
            ForEach(report.prLines, id: \.self) { line in
                Text(line)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .card(.plain)
    }

    private var segments: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let totalWeight = CGFloat(report.segments.reduce(0) { $0 + $1.weight })
            let width = max(0, proxy.size.width - spacing * CGFloat(report.segments.count - 1))
            HStack(spacing: spacing) {
                ForEach(report.segments) { segment in
                    Capsule()
                        .fill(segment.tone == .secondary ? Color.secondary.opacity(ChipTint.strokeOpacity) : segment.tone.color)
                        .frame(width: width * CGFloat(segment.weight) / max(1, totalWeight))
                        .accessibilityLabel(segment.label)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.accessibilityLabel)
    }
}

/// One timeline row; `opens` adds the chevron of a target milestone.
private struct MilestoneRowView: View {
    let row: MilestoneRow
    let opens: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Text(row.time)
                .font(TypeScale.time)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            SessionDot(tone: row.tone, isRing: false, size: 8)
            Text(row.text)
                .font(TypeScale.rowTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
