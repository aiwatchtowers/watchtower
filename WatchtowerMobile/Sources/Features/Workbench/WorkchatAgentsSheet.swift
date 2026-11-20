import SwiftUI

/// The toolbar's agents button (#2065): two people and the working count on an accent badge, or, with none working,
/// a dimmed `✓ N` on a faint capsule so it still reads as a button; a dimmed `?` while the live block cannot say.
struct WorkchatAgentsButton: View {
    let badge: WorkchatAgents.Badge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                Image(systemName: "person.2")
                switch badge {
                case let .working(count):
                    CountBadge(count: count, tone: .accent)
                case let .done(count):
                    Text(WorkchatAgentsText.doneBadge(count)).font(TypeScale.badge).monospacedDigit()
                case .unknown:
                    Text(WorkchatAgentsText.unknownBadge).font(TypeScale.badge)
                }
            }
            .foregroundStyle(isDimmed ? Color.secondary : Color.accentColor)
            .padding(.horizontal, isDimmed ? Spacing.regular : 0)
            .padding(.vertical, isDimmed ? Spacing.small : 0)
            .background(isDimmed ? Fill.rest : .clear, in: Capsule())
            .frame(minHeight: PhoneMetrics.minTouch)
        }
        .accessibilityLabel(WorkchatAgentsText.title)
        .accessibilityValue(WorkchatAgentsText.badgeValue(badge))
    }

    private var isDimmed: Bool {
        if case .working = badge { return false }
        return true
    }
}

/// The agents sheet: Working (type, description, and with the chat's live block the agent's current step and timer,
/// else "Running") and a collapsible Done · N, open by itself when nothing works. Closed with the toolbar's ✕; a row
/// with a route dismisses the sheet and opens its chat.
struct WorkchatAgentsSheet: View {
    let agents: WorkchatAgents
    /// Held by the host, so it outlives the sheet.
    @Binding var disclosure: WorkchatAgents.DoneDisclosure
    let onOpen: (SessionChatRoute) -> Void
    let onClose: () -> Void
    private var doneOpen: Bool { agents.doneIsOpen(disclosure) }

    /// The rows line up with the section header's text (its `Spacing.small` inset), not with the page.
    private static let rowInsets = EdgeInsets(top: Spacing.regular, leading: Spacing.small, bottom: Spacing.regular, trailing: Spacing.small)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // One timeline for the section, only while a row carries a timer; it stops with the sheet.
                    if agents.ticks {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            working(agents.working(at: context.date))
                        }
                    } else {
                        working(agents.working)
                    }
                    if !agents.done.isEmpty {
                        doneHeader
                        if doneOpen {
                            ForEach(agents.done) { agent in
                                row(agent, icon: .symbol("checkmark.circle", tone: .secondary), running: false)
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.large)
            }
            .navigationTitle(WorkchatAgentsText.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .accessibilityLabel(WorkchatAgentsText.close)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func working(_ rows: [WorkchatAgents.Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(WorkchatAgentsText.working, count: rows.count)
                ForEach(rows) { agent in
                    row(agent, icon: .session(tone: .green, isRing: false), running: true)
                }
            }
        }
    }

    private var doneHeader: some View {
        Button {
            disclosure = doneOpen ? .closed : .open
        } label: {
            HStack(spacing: Spacing.compact) {
                Image(systemName: doneOpen ? "chevron.down" : "chevron.right")
                    .font(TypeScale.capsHeader)
                    .frame(width: PhoneMetrics.iconColumn)
                Text(WorkchatAgentsText.done(agents.done.count)).font(TypeScale.sectionHeader)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(Self.rowInsets)
            .frame(minHeight: PhoneMetrics.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, agents.working.isEmpty ? Spacing.regular : Spacing.small)
    }

    @ViewBuilder
    private func row(_ agent: WorkchatAgents.Row, icon: FlatRowIcon, running: Bool) -> some View {
        let content = FlatRow(icon: icon, title: agent.type, titleLineLimit: 1, insets: Self.rowInsets) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(agent.description)
                if running, let action = agent.action {
                    HStack(spacing: Spacing.compact) {
                        if let symbol = agent.symbol { Image(systemName: symbol) }
                        Text(action).lineLimit(1).truncationMode(.middle)
                    }
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                }
            }
        } trailing: {
            HStack(spacing: Spacing.regular) {
                if running { status(agent) }
                if agent.route != nil { Image(systemName: "chevron.right").font(TypeScale.meta).foregroundStyle(.tertiary) }
            }
        }
        if let route = agent.route {
            Button { onOpen(route) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    /// A live row's timer; "Running" for a marker row without live data.
    @ViewBuilder
    private func status(_ agent: WorkchatAgents.Row) -> some View {
        if let elapsed = agent.elapsed {
            Text(elapsed).font(TypeScale.meta).monospacedDigit().foregroundStyle(.secondary)
        } else if agent.action == nil {
            Text(WorkchatAgentsText.running).font(TypeScale.meta).foregroundStyle(.secondary)
        }
    }
}
