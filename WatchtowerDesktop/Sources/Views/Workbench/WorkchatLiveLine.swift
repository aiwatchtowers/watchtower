import SwiftUI
import WatchtowerCore

/// The existing caption slot: no new panel or feed entry. The 👥 list
/// appears only by an explicit click and never changes the chat's layout.
/// While no turn runs the row keeps only the 👥 button, and only when the tab
/// has finished agents to list (#2065 spec §2).
struct WorkchatLiveLine: View {
    let snapshot: SessionFeedLive?
    let error: String?
    let loaded: Bool
    /// The session is busy (`WorkchatLivePresentation.busy`: a turn, background
    /// agents or an approval): the list then never reads a missing snapshot as
    /// "none working".
    let working: Bool
    /// A permission card stands in for the activity text; the 👥 list still
    /// reads the real snapshot.
    var activityHidden = false
    let stateAt: Date?
    /// The finished subagents of this pane, ordered (`WorkchatLivePresentation.done(from:)`).
    var done: [SessionFeedSubagent] = []
    /// The pane's key in `memory` (`"session-<id>"`, `"session-<id>/<toolUseID>"`).
    let paneKey: String
    let memory: WorkchatPaneMemory
    /// The feed behind Done was read once; a later failure keeps Done.
    var feedLoaded = true
    var feedError: String?
    let onRetry: () -> Void
    /// Reads the feed again from the list's error state.
    var onRetryList: () -> Void = {}
    let onOpenAgent: (SessionFeedSubagent) -> Void
    /// An optional clock anchor also lets the registered visual fixtures
    /// compare current/last/stale at the same deterministic instant.
    var referenceDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var agentsOpen = false
    /// The last conversation a snapshot named: the popover closes only when
    /// it changes, not when the snapshot goes away at turn end.
    @State private var lastConversation: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = referenceDate ?? context.date
            let stepsOpen = memory.stepsOpen(paneKey)
            let row = WorkchatLivePresentation.row(snapshot: snapshot, error: error, loaded: loaded, working: working,
                                                   stateAt: stateAt, now: now, done: done, activityHidden: activityHidden,
                                                   stepsOpen: stepsOpen)
            // A permission card hides the steps: the slot gets no snapshot then.
            let steps = WorkchatLivePresentation.stepsSlot(snapshot: activityHidden ? nil : snapshot, error: error,
                                                           working: working, now: now)
            VStack(spacing: 0) {
                if stepsOpen, let steps { WorkchatStepsList(slot: steps) }
                line(row: row, now: now)
            }
        }
        .onChange(of: snapshot?.conversation, initial: true) { _, conversation in
            guard let conversation else { return }
            if let lastConversation, lastConversation != conversation { agentsOpen = false }
            lastConversation = conversation
        }
        .onChange(of: paneKey) { _, _ in agentsOpen = false; lastConversation = nil }
    }

    private func line(row: WorkchatLivePresentation.Row?, now: Date) -> some View {
        HStack(spacing: Spacing.compact) {
            if let row {
                if row.activity {
                    if row.chevron != nil {
                        // The line opens and closes the steps above it (⌥↓ in the composer does too).
                        Button { memory.toggleSteps(paneKey) } label: {
                            activity(row).contentShape(Rectangle())
                        }
                        // The line itself is the control, as the mock draws it: no plate.
                        .buttonStyle(.plain)
                        .accessibilityHint(WorkchatLivePresentation.stepsToggleHint(open: row.chevron == "chevron.down"))
                    } else {
                        activity(row)
                    }
                    if row.retry { Button(WorkchatLivePresentation.retryTitle, action: onRetry).buttonStyle(.kitQuiet) }
                }
                Spacer(minLength: Spacing.compact)
                if let badge = row.agentsBadge {
                    agentsButton(row: row, badge: badge, now: now)
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

    /// The chevron (with steps), the step or turn summary and its symbol.
    private func activity(_ row: WorkchatLivePresentation.Row) -> some View {
        HStack(spacing: Spacing.compact) {
            if let chevron = row.chevron {
                Image(systemName: chevron)
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: IconSize.header)
            }
            Image(systemName: row.symbol)
                .frame(width: IconSize.header)
                .symbolEffect(.pulse, isActive: row.pulse && !reduceMotion)
            Text(row.text).lineLimit(1).truncationMode(.middle).help(row.text)
        }
    }

    private func agentsButton(row: WorkchatLivePresentation.Row, badge: String, now: Date) -> some View {
        let label = WorkchatLivePresentation.agentsLabel(row) ?? WorkchatLivePresentation.listTitle
        return Button { agentsOpen.toggle() } label: {
            HStack(spacing: Spacing.small) {
                Image(systemName: row.agentsSymbol)
                Text(badge).monospacedDigit()
            }
            .foregroundStyle(row.agentsDimmed ? .tertiary : .secondary)
            .padding(.horizontal, Spacing.compact)
            .padding(.vertical, Spacing.tight)
            .background(agentsOpen ? Fill.hover : (row.agentsDimmed ? Fill.rest : .clear), in: Capsule())
            .contentShape(Capsule())
        }
        // A capsule badge, as the approved mock draws it; the quiet style's plate is a rounded rectangle.
        .buttonStyle(.plain)
        .disabled(!row.agentsEnabled)
        .opacity(row.agentsEnabled ? 1 : 0.5)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $agentsOpen, arrowEdge: .bottom) {
            WorkchatAgentsPopover(
                list: WorkchatLivePresentation.agentsList(snapshot: snapshot, error: error, feedLoaded: feedLoaded,
                                                          feedError: feedError, done: done, idle: !working, now: now),
                agentsMore: snapshot?.agentsMore ?? 0,
                paneKey: paneKey,
                memory: memory,
                onRetry: onRetryList
            ) {
                agentsOpen = false
                onOpenAgent($0)
            }
        }
    }
}

/// The 👥 list's popover body: WORKING rows (or a note), then the collapsible
/// Done section. Shared with the registered design shots.
struct WorkchatAgentsPopover: View {
    let list: WorkchatLivePresentation.AgentsList
    var agentsMore = 0
    let paneKey: String
    let memory: WorkchatPaneMemory
    var onRetry: () -> Void = {}
    let onOpenAgent: (SessionFeedSubagent) -> Void

    private static let twoLineRow: CGFloat = ListLayout.rowMinHeight + Spacing.large

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(WorkchatLivePresentation.listTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch list.state {
            case .loading:
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(WorkchatLivePresentation.listLoading).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.regular)
            case .error:
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.circle")
                    Text(WorkchatLivePresentation.listError)
                    Spacer(minLength: Spacing.regular)
                    Button(WorkchatLivePresentation.retryTitle, action: onRetry).buttonStyle(.kitSecondary).controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(Tone.warning)
                .padding(.vertical, Spacing.small)
            case .ready:
                workingSection
                if !list.done.isEmpty { doneSection }
            }
        }
        .padding(Spacing.medium)
        .frame(width: PaneWidth.sideListMax, alignment: .leading)
        .popoverSurface()
    }

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(WorkchatLivePresentation.workingTitle)
                .font(.caption2.weight(.semibold))
                .tracking(Tracking.caps)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Spacing.regular)
                .padding(.top, Spacing.small)
            if let note = list.workingNote {
                HStack(spacing: Spacing.compact) {
                    if note == WorkchatLivePresentation.unknownAgents {
                        Image(systemName: "questionmark.circle").frame(width: IconSize.header)
                    }
                    Text(note)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.small)
            }
            capped(count: list.working.count) {
                ForEach(list.working) { row in
                    agentRow(symbol: row.agent.action.map { WorkchatActivityPresenter.symbol(for: $0.tool) } ?? "person.2",
                             tint: nil, title: row.heading, subtitle: row.subtitle, trailing: row.elapsed) {
                        onOpenAgent(row.agent.ref)
                    }
                    .disabled(!row.agent.canOpen)
                }
            }
            if agentsMore > 0 {
                Text(WorkchatLivePresentation.moreAgents(agentsMore))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.regular)
            }
        }
    }

    private var doneSection: some View {
        let open = memory.doneOpen(paneKey, default: list.doneOpenByDefault)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            Button {
                memory.setDoneOpen(paneKey, !open)
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: IconSize.chevron, weight: .semibold))
                        .frame(width: IconSize.header)
                    Text(list.doneTitle)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kitRow(isSelected: false)
            }
            .buttonStyle(.plain)
            if open {
                capped(count: list.done.count) {
                    ForEach(list.done) { row in
                        agentRow(symbol: "checkmark.circle", tint: Tone.success, title: row.title, subtitle: row.subtitle,
                                 trailing: nil) {
                            onOpenAgent(row.ref)
                        }
                    }
                }
            }
        }
    }

    /// At most `maxDoneRows` rows tall; the rest scroll.
    @ViewBuilder
    private func capped(count: Int, @ViewBuilder rows: () -> some View) -> some View {
        if count > WorkchatLivePresentation.maxDoneRows {
            let shown = CGFloat(WorkchatLivePresentation.maxDoneRows)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.tight) { rows() }
            }
            .frame(height: shown * Self.twoLineRow + (shown - 1) * Spacing.tight)
        } else {
            VStack(alignment: .leading, spacing: Spacing.tight) { rows() }
        }
    }

    private func agentRow(
        symbol: String,
        tint: Color?,
        title: String,
        subtitle: String,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.regular) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: IconSize.header)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(title).font(.callout).foregroundStyle(.primary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: Spacing.small)
                if let trailing { Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .kitRow(isSelected: false)
        }
        // A full-width list row: the quiet style would fix its intrinsic size.
        .buttonStyle(.plain)
    }
}
