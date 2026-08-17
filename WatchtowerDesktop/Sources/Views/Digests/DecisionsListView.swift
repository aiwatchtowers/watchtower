import SwiftUI
import WatchtowerCore

/// The Decisions segment's list: the consolidated decisions ledger
/// (`ideas WHERE kind = 'decision'`), most-recently-mentioned first. Replaces
/// the old digest-scanned, fuzzy-deduped flat decisions list.
struct DecisionsListView: View {
    let viewModel: DigestViewModel
    @Binding var selectedID: Int?
    @Binding var expandedIDs: Set<Int>
    @Binding var searchText: String
    @Binding var showAll: Bool

    /// Read once when the view is created (the `SettingsView` precedent) —
    /// only to tell the "nothing mined yet" empty state apart from the
    /// "mining is switched off in config.yaml" one. `ideas.enabled` has no
    /// Settings toggle of its own by owner decision, so a live observation
    /// would buy nothing here.
    @State private var config = ConfigService()

    /// Mirrors `IdeaQueries.unreadDecisionCount`'s predicate: never seen, or
    /// seen but re-flagged since.
    private func isUnread(_ idea: Idea) -> Bool {
        idea.seenAt == nil || idea.needsReview
    }

    private var filteredDecisions: [Idea] {
        var items = viewModel.ledgerDecisions
        if !showAll {
            items = items.filter(isUnread)
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            items = items.filter { idea in
                idea.title.lowercased().contains(query) || idea.essence.lowercased().contains(query)
            }
        }
        return items
    }

    private func toggleExpanded(_ idea: Idea) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedIDs.contains(idea.id) {
                expandedIDs.remove(idea.id)
            } else {
                expandedIDs.insert(idea.id)
                if isUnread(idea) {
                    viewModel.markDecisionSeen(id: idea.id)
                }
            }
        }
    }

    var body: some View {
        if filteredDecisions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredDecisions) { idea in
                        decisionListItem(idea)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Empty State

    /// Three cases, in priority order: the ledger has rows but the current
    /// search/unread filter hides them all (the `ProjectMapView`
    /// `emptyState(isFiltered:)` precedent); the ledger is empty and the
    /// registry that fills it is switched off; the ledger is simply empty
    /// and waiting for the miner.
    @ViewBuilder
    private var emptyState: some View {
        let isFiltered = !viewModel.ledgerDecisions.isEmpty

        VStack(spacing: 12) {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle" : "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(emptyTitle(isFiltered: isFiltered))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(emptyMessage(isFiltered: isFiltered))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func emptyTitle(isFiltered: Bool) -> String {
        if isFiltered { return "No matching decisions" }
        return config.ideasEnabled ? "No decisions yet" : "Ideas mining is disabled"
    }

    private func emptyMessage(isFiltered: Bool) -> String {
        if isFiltered {
            return showAll
                ? "No decision matches your search."
                : "No unread decisions — switch to All to see the whole ledger."
        }
        if !config.ideasEnabled {
            return "Set ideas.enabled in config.yaml to mine decisions from Slack, meetings, email, and Jira."
        }
        return "Decisions mined from Slack, meetings, email, and Jira will collect here."
    }

    private func decisionListItem(_ idea: Idea) -> some View {
        let isSelected = selectedID == idea.id
        let bgColor: Color = isSelected
            ? Color.accentColor.opacity(0.15)
            : isUnread(idea)
                ? Color.blue.opacity(0.06)
                : Color.clear

        return decisionRow(idea)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = idea.id }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bgColor, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
    }

    private func decisionRow(_ idea: Idea) -> some View {
        let expanded = expandedIDs.contains(idea.id)
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor(idea))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(statusLabel(idea))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor(idea))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(statusColor(idea).opacity(0.12), in: Capsule())

                    Spacer()

                    if let date = TimeFormatting.parseISO(idea.lastMentionAt) {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        toggleExpanded(idea)
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 6) {
                    if isUnread(idea) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                    Text(idea.title)
                        .font(.subheadline)
                        .fontWeight(isUnread(idea) ? .medium : .regular)
                        .lineLimit(expanded ? nil : 3)
                }

                if let sources = viewModel.decisionMentionSources[idea.id], !sources.isEmpty {
                    sourceGlyphs(sources)
                }

                if expanded {
                    decisionExpandedContent(idea)
                }
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func decisionExpandedContent(_ idea: Idea) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if !idea.essence.isEmpty {
                Text(idea.essence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            Button {
                selectedID = idea.id
            } label: {
                Label("Open details", systemImage: "arrow.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Compact per-source glyphs (spec B3 row spec: "title, source glyphs
    /// from mentions, relative time, unread dot") — which sources have
    /// mentioned this decision, not the mentions themselves.
    private func sourceGlyphs(_ sources: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(sources.sorted(), id: \.self) { source in
                Image(systemName: sourceGlyph(source))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(source.capitalized)
            }
        }
    }

    private func sourceGlyph(_ source: String) -> String {
        switch IdeaMention.Source(rawValue: source) ?? .owner {
        case .slack: "number"
        case .meeting: "video"
        case .gmail: "envelope"
        case .jira: "ticket"
        case .owner: "person.fill"
        }
    }

    private func statusLabel(_ idea: Idea) -> String {
        idea.statusRaw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func statusColor(_ idea: Idea) -> Color {
        switch idea.status {
        case .active: .green
        case .superseded: .purple
        case .reversed: .red
        case .rejected: .red
        default: .orange
        }
    }
}
