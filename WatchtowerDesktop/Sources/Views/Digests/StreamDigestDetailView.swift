import SwiftUI

/// Detail pane for the `.stream` case of `DigestFeedEntry` — a Gmail/Jira
/// stream digest (Task 9). Renders each topic's summary plus its idea/decision
/// candidates. Marks the digest read on appear, mirroring `DigestDetailView`'s
/// mark-on-selection convention (a stream digest has no list-level `onChange`
/// hook, so the detail pane owns it instead).
struct StreamDigestDetailView: View {
    let digest: StreamDigest
    let viewModel: DigestViewModel
    var onClose: (() -> Void)?

    @State private var jiraSiteURL: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                let topics = digest.parsedTopics
                if topics.isEmpty {
                    Text("No topics in this digest.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                        topicSection(topic)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(sourceLabel)
        .task {
            jiraSiteURL = JiraConfigHelper.readSiteURL()
            viewModel.markStreamRead(id: digest.id)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(sourceLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(sourceColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(sourceColor.opacity(0.12), in: Capsule())

            if !digest.scope.isEmpty {
                Text(digest.scope)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            Spacer()

            Text(TimeFormatting.relativeTime(from: digest.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let onClose {
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var sourceLabel: String {
        digest.source == "jira" ? "Jira" : "Gmail"
    }

    private var sourceColor: Color {
        digest.source == "jira" ? .indigo : .red
    }

    // MARK: - Topics

    private func topicSection(_ topic: StreamTopic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title)
                .font(.headline)

            if let summary = topic.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            candidateList("Ideas", systemImage: "lightbulb", color: .yellow, candidates: topic.ideas)
            candidateList("Decisions", systemImage: "arrow.triangle.branch", color: .orange, candidates: topic.decisions)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func candidateList(
        _ title: String, systemImage: String, color: Color, candidates: [StreamCandidate]?
    ) -> some View {
        if let candidates, !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)

                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    candidateRow(candidate, accent: color)
                }
            }
        }
    }

    private func candidateRow(_ candidate: StreamCandidate, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accent.opacity(0.6))
                .frame(width: 2, height: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.text)
                    .font(.caption)
                HStack(spacing: 6) {
                    if let author = candidate.author, !author.isEmpty {
                        Text(author)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let ref = candidate.ref, !ref.isEmpty {
                        refView(ref)
                    }
                }
            }
        }
    }

    /// A wrong link is worse than no link (the `IdeaDetailPane.mentionURL`
    /// precedent): only a Jira ref, resolved against a known site, gets a
    /// tappable `Link`. Gmail has no Desktop permalink helper (checked —
    /// none exists), so its `"gmail:<acct>:<threadID>"` ref renders as plain
    /// monospace text rather than inventing a URL scheme.
    @ViewBuilder
    private func refView(_ ref: String) -> some View {
        if digest.source == "jira", let jiraSiteURL, !jiraSiteURL.isEmpty,
           let url = URL(string: "\(jiraSiteURL)/browse/\(ref)") {
            Link(destination: url) {
                Text(ref)
                    .font(.caption2.monospaced())
            }
            .buttonStyle(.borderless)
        } else {
            Text(ref)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}
