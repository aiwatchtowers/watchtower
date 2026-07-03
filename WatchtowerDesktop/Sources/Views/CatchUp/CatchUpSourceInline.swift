import SwiftUI

// MARK: - Inline source detail
//
// Compact, read-only renderings shown inline under a Catch-Up source row when the
// operator expands it. They mirror the key content of the full Digest/Track
// detail screens (summary, topics, decisions, tracks / narrative, checklist,
// people) without the heavy DigestDetailView / TrackDetailView and their separate
// view models — the review pane only needs to *show* the source, not act on it.

/// Compact digest rendering: summary, topics, decisions, and tracks. Decisions
/// ride inside the digest, so this is also how a theme's "decisions" surface.
struct DigestInlineDetail: View {
    let digest: Digest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !digest.summary.isEmpty {
                Text(digest.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let topics = digest.parsedTopics
            if !topics.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            let decisions = digest.parsedDecisions
            if !decisions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Decisions", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    ForEach(decisions) { decision in
                        HStack(alignment: .top, spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(decisionImportanceColor(decision.resolvedImportance))
                                .frame(width: 2, height: 14)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(decision.text)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                if let by = decision.by, !by.isEmpty {
                                    Text(by)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            let actions = digest.parsedTracks
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Tracks", systemImage: "checkmark.circle")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    ForEach(actions) { item in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: item.status == "done" ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.status == "done" ? .green : .secondary)
                                .font(.caption2)
                                .padding(.top, 1)
                            Text(item.text)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func decisionImportanceColor(_ importance: String) -> Color {
        switch importance {
        case "high": .red
        case "low": .gray
        default: .orange
        }
    }
}

/// Compact track rendering: narrative text, context, checklist progress, people.
struct TrackInlineDetail: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !track.text.isEmpty {
                Text(track.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !track.context.isEmpty {
                Text(track.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let sub = track.decodedSubItems
            if !sub.isEmpty {
                let progress = track.subItemsProgress
                VStack(alignment: .leading, spacing: 4) {
                    Label("Checklist \(progress.done)/\(progress.total)", systemImage: "checklist")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    ForEach(sub) { item in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isDone ? .green : .secondary)
                                .font(.caption2)
                                .padding(.top, 1)
                            Text(item.text)
                                .font(.caption)
                                .strikethrough(item.isDone)
                        }
                    }
                }
            }

            let people = track.decodedParticipants
            if !people.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(people.map(\.name).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
