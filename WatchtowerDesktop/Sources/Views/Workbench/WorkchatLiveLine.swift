import SwiftUI
import WatchtowerCore

/// The existing caption slot: no new panel or feed entry. The agent picker
/// appears only by an explicit click and never changes the chat's layout.
struct WorkchatLiveLine: View {
    let snapshot: SessionFeedLive?
    let error: String?
    let loaded: Bool
    let working: Bool
    let stateAt: Date?
    let onRetry: () -> Void
    let onOpenAgent: (SessionFeedSubagent) -> Void
    /// An optional clock anchor also lets the registered visual fixtures
    /// compare current/last/stale at the same deterministic instant.
    var referenceDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var agentsOpen = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = referenceDate ?? context.date
            let row = WorkchatLivePresentation.row(snapshot: snapshot, error: error, loaded: loaded,
                                                   working: working, stateAt: stateAt, now: now)
            HStack(spacing: Spacing.compact) {
                if let row {
                    Image(systemName: row.symbol)
                        .frame(width: IconSize.header)
                        .symbolEffect(.pulse, isActive: row.pulse && !reduceMotion)
                    Text(row.text).lineLimit(1).truncationMode(.middle).help(row.text)
                    if row.retry { Button(WorkchatLivePresentation.retryTitle, action: onRetry).buttonStyle(.kitQuiet) }
                    Spacer(minLength: Spacing.compact)
                    if let badge = row.agentsBadge {
                        Button { agentsOpen.toggle() } label: {
                            HStack(spacing: Spacing.small) {
                                Image(systemName: "person.2")
                                Text(badge).monospacedDigit()
                            }
                        }
                        .buttonStyle(.kitQuiet)
                        .disabled(!row.agentsEnabled)
                        .help(badge == "?" ? WorkchatLivePresentation.unknownAgents : WorkchatLivePresentation.agentsHelp)
                        .popover(isPresented: $agentsOpen, arrowEdge: .bottom) {
                            WorkchatRunningAgentsPicker(snapshot: snapshot, error: error, now: now) {
                                agentsOpen = false
                                onOpenAgent($0)
                            }
                        }
                    }
                    if let elapsed = row.elapsed {
                        Text(elapsed).monospacedDigit().accessibilityHidden(true)
                    }
                } else {
                    Text(verbatim: " ").accessibilityHidden(true)
                }
            }
            .font(.caption)
            .foregroundStyle(row?.warning == true ? Tone.warning : .secondary)
            .padding(.horizontal, Spacing.large)
            .controlSize(.mini)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ListLayout.lineMinHeight)
            .onChange(of: row?.warning) { _, warning in if warning == true { agentsOpen = false } }
        }
        .onChange(of: working) { _, active in if !active { agentsOpen = false } }
        .onChange(of: snapshot?.conversation) { _, _ in agentsOpen = false }
    }

}

/// Shared with the registered actual-view design shots. This is the same
/// flat picker content used inside the anchored native popover.
struct WorkchatRunningAgentsPicker: View {
    let snapshot: SessionFeedLive?
    let error: String?
    let now: Date
    let onOpenAgent: (SessionFeedSubagent) -> Void

    var body: some View {
        let rows = WorkchatLivePresentation.agentRows(snapshot, error: error, now: now)
        return VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(WorkchatLivePresentation.agentsTitle(count: rows.count + (snapshot?.agentsMore ?? 0)))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if snapshot?.agentsState != "known" {
                Text(WorkchatLivePresentation.unknownAgents).font(.caption).foregroundStyle(.secondary)
            }
            if !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.large) {
                        ForEach(rows) { row in
                            Button {
                                onOpenAgent(row.agent.ref)
                            } label: {
                                HStack(alignment: .top, spacing: Spacing.regular) {
                                    VStack(alignment: .leading, spacing: Spacing.small) {
                                        Text(row.title)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(row.action)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: Spacing.small)
                                    if let elapsed = row.elapsed { Text(elapsed).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            // Quiet buttons fix their intrinsic size; a picker row
                            // must instead wrap long tasks within its column.
                            .buttonStyle(.plain)
                            .disabled(!row.agent.canOpen)
                        }
                        if let more = snapshot?.agentsMore, more > 0 {
                            Text(WorkchatLivePresentation.moreAgents(more)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count), 3) * ListLayout.rowMinHeight * 2)
            }
        }
        .frame(width: PaneWidth.sideListMax)
        .popoverSurface()
    }
}
