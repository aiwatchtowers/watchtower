import SwiftUI

/// The toolbar's agents button (#2065): two people and the working count on an accent badge, or, with none working,
/// a dimmed `✓ N` on a faint capsule so it still reads as a button.
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
                }
            }
            .foregroundStyle(isDone ? Color.secondary : Color.accentColor)
            .padding(.horizontal, isDone ? Spacing.regular : 0)
            .padding(.vertical, isDone ? Spacing.small : 0)
            .background(isDone ? Fill.rest : .clear, in: Capsule())
            .frame(minHeight: PhoneMetrics.minTouch)
        }
        .accessibilityLabel(WorkchatAgentsText.title)
    }

    private var isDone: Bool {
        if case .done = badge { return true }
        return false
    }
}

/// The agents sheet: Working (type, description, "Running") and a collapsible Done · N, open by itself when
/// nothing works. Closed with the toolbar's ✕; a row with a route dismisses the sheet and opens its chat.
struct WorkchatAgentsSheet: View {
    let agents: WorkchatAgents
    let onOpen: (SessionChatRoute) -> Void
    let onClose: () -> Void
    /// The owner flipped Done from its default.
    @State private var doneFlipped = false

    private var doneOpen: Bool { agents.doneOpenByDefault != doneFlipped }

    /// The rows line up with the section header's text (its `Spacing.small` inset), not with the page.
    private static let rowInsets = EdgeInsets(top: Spacing.regular, leading: Spacing.small, bottom: Spacing.regular, trailing: Spacing.small)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !agents.working.isEmpty {
                        SectionHeader(WorkchatAgentsText.working, count: agents.working.count)
                        ForEach(agents.working) { agent in
                            row(agent, icon: .session(tone: .green, isRing: false), running: true)
                        }
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

    private var doneHeader: some View {
        Button {
            doneFlipped.toggle()
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
            Text(agent.description)
        } trailing: {
            HStack(spacing: Spacing.regular) {
                if running { Text(WorkchatAgentsText.running).font(TypeScale.meta).foregroundStyle(.secondary) }
                if agent.route != nil { Image(systemName: "chevron.right").font(TypeScale.meta).foregroundStyle(.tertiary) }
            }
        }
        if let route = agent.route {
            Button { onOpen(route) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
