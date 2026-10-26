import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// A session's report and timeline (spec §4.8, §5.3), reached from the
/// workchat's actions menu "Report and timeline" (mockup 13): one card with
/// the title, the Mac's state, the summary, the progress bar and where it
/// ran, then the session's target and the timeline. Opening it asks the Mac
/// for a fresh report.
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
            VStack(alignment: .leading, spacing: 0) {
                summaryCard(detail)
                if viewModel.waitingForKeys {
                    Text("Unlock this iPhone to see the latest report.")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.regular)
                }
                if let target = detail.target {
                    SectionHeader("Targets")
                    targetRow(target)
                }
                timeline(detail)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.regular)
        }
        .background(Color(.systemBackground))
    }

    private func summaryCard(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(detail.title)
                .font(TypeScale.rowEmphasis)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Spacing.compact) {
                SessionDot(tone: detail.state.tone, isRing: detail.state.isRing)
                Text(detail.state.caption)
            }
            .font(.footnote)
            .foregroundStyle(detail.state.tone.color)
            .accessibilityElement(children: .combine)
            if let report = detail.report {
                SessionReportBody(report: report)
            }
            MetaLine(items: whereItems(detail)).font(TypeScale.meta)
        }
        .card(.plain)
    }

    private func whereItems(_ detail: SessionDetailModel) -> [MetaItem] {
        var items = [MetaItem(text: detail.agentLine, tone: .secondary, role: .info)]
        if let branch = detail.branch {
            items.append(MetaItem(text: branch, tone: .secondary, role: .info))
        }
        return items
    }

    private func targetRow(_ target: SessionDetailModel.TargetChip) -> some View {
        NavigationLink(value: BoardTargetRoute(id: target.id)) {
            FlatRow(icon: .symbol("scope", tone: .accent), title: target.label, titleLineLimit: 1, insets: Card.padding) {
                EmptyView()
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .card(.plain, padding: EdgeInsets())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Target \(target.label)")
    }

    private func timeline(_ detail: SessionDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Timeline")
            if let empty = detail.timelineEmptyText {
                Text(empty)
                    .font(.footnote)
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
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.top, Spacing.regular)
            }
        }
    }
}

/// The report inside the card: the summary, the PRs, the segmented bar and
/// "2 / 7 targets".
private struct SessionReportBody: View {
    let report: SessionReportSection

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(report.summary, id: \.self) { line in
                Text(line).font(TypeScale.rowTitle)
            }
            ForEach(report.prLines, id: \.self) { line in
                Text(line).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            if !report.segments.isEmpty {
                segments
            }
            Text(report.progressLabel).font(TypeScale.time).foregroundStyle(.secondary)
        }
    }

    private var segments: some View {
        GeometryReader { proxy in
            let spacing = Spacing.tight
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
        .frame(height: PhoneMetrics.segmentBar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.accessibilityLabel)
    }
}

/// One timeline row (mockup 13 `.tl`): time, dot and text; `opens` adds the
/// chevron of a target milestone.
private struct MilestoneRowView: View {
    let row: MilestoneRow
    let opens: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Text(row.time)
                .font(TypeScale.time)
                .foregroundStyle(.secondary)
                .frame(width: PhoneMetrics.timeColumn, alignment: .leading)
            SessionDot(tone: row.tone, isRing: false, size: PhoneMetrics.timelineDot)
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
        .frame(minHeight: PhoneMetrics.minTouch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
