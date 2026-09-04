import SwiftUI
import WatchtowerCore

// MARK: - Inline source detail, part two
//
// The five areas the absence recap cites that `CatchUpSourceInline.swift` (the
// digest and track renderings) does not cover. Same contract as those two:
// compact, read-only, no view model of their own — the recap only needs to
// *show* the source, not act on it.

/// A Gmail/Jira stream digest: which stream it came from, then its topics.
struct StreamDigestInline: View {
    let digest: StreamDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(Array(digest.parsedTopics.enumerated()), id: \.offset) { _, topic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let summary = topic.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var caption: String {
        digest.scope.isEmpty ? digest.source.capitalized : "\(digest.source.capitalized) · \(digest.scope)"
    }
}

/// A meeting recap — shared by the `recaps` area (a `meeting_recaps` row) and
/// the `transcripts` area (an ad-hoc recording's `summary_json`), which decode
/// to the same `MeetingRecap.Content`.
struct MeetingRecapInline: View {
    let title: String
    let content: MeetingRecap.Content?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            if let content {
                if !content.summary.isEmpty {
                    Text(content.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                list("Decisions", content.keyDecisions)
                list("Action items", content.actionItems)
            } else {
                Text("No recap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func list(_ label: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A ledger decision plus the most recent thing said about it — a one-line
/// decision is only checkable with its quote.
struct DecisionInline: View {
    let idea: Idea
    let mentions: [IdeaMention]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(idea.title)
                .font(.caption)
                .fontWeight(.medium)
                .textSelection(.enabled)
            if !idea.essence.isEmpty {
                Text(idea.essence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            // Mentions come back oldest first (IdeaQueries.fetchMentions).
            if let latest = mentions.last, !latest.quote.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(latest.quote)”")
                        .font(.caption)
                        .italic()
                        .textSelection(.enabled)
                    if !latest.author.isEmpty {
                        Text(latest.author)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// An actionable inbox item: what was said, who said it and where, and a way out
/// to Slack. `origin` is resolved by the ViewModel — the row itself carries only
/// namespaced Slack ids.
struct InboxItemInline: View {
    let item: InboxItem
    let origin: String
    let url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let url {
                Link("Open in Slack", destination: url)
                    .font(.caption2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var caption: String {
        [item.triggerType, origin].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A target that came due inside the window.
struct TargetInline: View {
    let target: Target

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(target.text)
                .font(.caption)
                .fontWeight(.medium)
                .textSelection(.enabled)
            if !target.intent.isEmpty {
                Text(target.intent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var caption: String {
        var parts: [String] = []
        if !target.dueDate.isEmpty {
            parts.append("due \(target.dueDate)")
        }
        parts.append(target.status.replacingOccurrences(of: "_", with: " "))
        parts.append(target.priority)
        return parts.joined(separator: " · ")
    }
}
