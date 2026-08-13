import SwiftUI

/// The Decisions segment's list: the consolidated decisions ledger
/// (`ideas WHERE kind = 'decision'`), most-recently-mentioned first. Replaces
/// the old digest-scanned, fuzzy-deduped flat decisions list.
struct DecisionsListView: View {
    let viewModel: DigestViewModel
    @Binding var selectedID: Int?
    @Binding var expandedIDs: Set<Int>
    @Binding var searchText: String
    @Binding var showAll: Bool

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
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredDecisions) { idea in
                    decisionListItem(idea)
                }
            }
            .padding(.vertical, 4)
        }
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
