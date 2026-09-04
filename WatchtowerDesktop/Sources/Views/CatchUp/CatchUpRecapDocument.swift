import SwiftUI
import WatchtowerCore

// MARK: - CatchUpRecapDocument
//
// One absence recap, read top to bottom: what the window covered, the TL;DR,
// then the four body sections. Every claim carries its sources, which expand
// inline (CatchUpRefList) rather than navigating away — reading the recap should
// never cost the reader their place in it.
struct CatchUpRecapDocument: View {
    let recap: CatchUpRecap
    let vm: CatchUpViewModel

    @State private var correction = ""

    var body: some View {
        // Decode once per render: `decodedBody` re-parses the JSON on every read.
        let content = recap.decodedBody
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusNotice(content)
                    if !recap.tldr.isEmpty {
                        Text(recap.tldr)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    sections(content)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionBar
        }
        // Reset the correction field when switching to a different recap.
        .id(recap.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CatchUpRecap.windowLabel(
                from: Date(timeIntervalSince1970: recap.periodFrom),
                to: Date(timeIntervalSince1970: recap.periodTo)
            ))
            .font(.title2)
            .textSelection(.enabled)

            Text(recap.decodedCoverage.summaryLine { TimeFormatting.shortTime($0) })
                .font(.caption)
                .foregroundStyle(.secondary)

            if recap.regenOfID != nil {
                Label("Regenerated from an earlier recap", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusNotice(_ content: CatchUpRecapBody) -> some View {
        if recap.isBuilding {
            ProgressView("Building the recap…")
                .controlSize(.small)
        } else if recap.isFailed {
            VStack(alignment: .leading, spacing: 8) {
                Label(recap.error.isEmpty ? "This recap failed to build." : recap.error,
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                Button("Retry") { vm.regenerate(comment: "") }
                    .disabled(vm.isBuilding)
            }
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        } else if recap.isReady && content.isEmpty {
            Text("Quiet — nothing happened in this window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Body sections

    @ViewBuilder
    private func sections(_ content: CatchUpRecapBody) -> some View {
        if !content.topics.isEmpty {
            section("What happened", "text.alignleft") {
                ForEach(content.topics.indices, id: \.self) { index in
                    CatchUpTopicCard(index: index, topic: content.topics[index], vm: vm)
                }
            }
        }

        if !content.decisions.isEmpty {
            section("Decisions", "arrow.triangle.branch") {
                ForEach(Array(content.decisions.enumerated()), id: \.offset) { _, entry in
                    entryBlock(text: entry.text, refs: entry.refs)
                }
            }
        }

        if !content.meetings.isEmpty {
            section("Meetings", "person.2") {
                ForEach(Array(content.meetings.enumerated()), id: \.offset) { _, meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                        if !meeting.summary.isEmpty {
                            Text(meeting.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        CatchUpRefList(refs: meeting.refs, vm: vm)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        if !content.needsYou.isEmpty {
            section("For you", "person.fill.questionmark") {
                ForEach(Array(content.needsYou.enumerated()), id: \.offset) { _, need in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Self.needSymbol(need.kind))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                        entryBlock(text: need.text, refs: need.refs)
                    }
                }
            }
        }
    }

    private func entryBlock(text: String, refs: [CatchUpRef]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            CatchUpRefList(refs: refs, vm: vm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(
        _ title: String, _ symbol: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Needs-you kinds, as the compose prompt emits them.
    private static func needSymbol(_ kind: String) -> String {
        switch kind {
        case "mention": "at"
        case "dm": "bubble.left"
        case "email": "envelope"
        case "track": "checkmark.circle"
        case "target_due": "flag"
        default: "circle"
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Correction…", text: $correction)
                    .textFieldStyle(.roundedBorder)
                Button("Regenerate") {
                    vm.regenerate(comment: correction)
                    correction = ""
                }
                .disabled(vm.isBuilding)
                .help("Rebuild this window, applying the correction")
            }

            HStack {
                Spacer()
                if recap.isAcknowledged {
                    Label(caughtUpLabel, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else if recap.isReady {
                    Button("I'm caught up") {
                        Task { await vm.acknowledge() }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Mark everything in this window read")
                }
            }
        }
        .padding(12)
    }

    private var caughtUpLabel: String {
        guard let stamp = recap.acknowledgedAt, let at = TimeFormatting.parseISO(stamp) else {
            return "Caught up"
        }
        return "Caught up \(TimeFormatting.relativeTime(from: at))"
    }
}

// MARK: - CatchUpTopicCard

/// One narrative topic — the recap's main unit. Carries its own sources and its
/// own feedback affordance, because feedback is per topic (`catchup feedback
/// <id> --topic N`), not per recap.
struct CatchUpTopicCard: View {
    let index: Int
    let topic: CatchUpTopic
    let vm: CatchUpViewModel

    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topic.title)
                    .font(.headline)
                    .textSelection(.enabled)
                priorityChip
                Spacer(minLength: 8)
                ratingButtons
            }

            if !topic.narrative.isEmpty {
                Text(topic.narrative)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !topic.refs.isEmpty {
                DisclosureGroup("Sources (\(topic.refs.count))") {
                    CatchUpRefList(refs: topic.refs, vm: vm)
                        .padding(.top, 6)
                }
                .font(.caption)
            }

            HStack(spacing: 6) {
                TextField("What's wrong with this topic?", text: $comment)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Send") { submit(rating: -1) }
                    .disabled(comment.isEmpty)
                    .help("Send as a correction — it teaches the source pipelines and may regenerate the recap")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var ratingButtons: some View {
        HStack(spacing: 4) {
            Button {
                submit(rating: 1)
            } label: {
                Image(systemName: "hand.thumbsup")
            }
            .buttonStyle(.borderless)
            .help("Helpful")

            Button {
                submit(rating: -1)
            } label: {
                Image(systemName: "hand.thumbsdown")
            }
            .buttonStyle(.borderless)
            .help("Not helpful")
        }
        .font(.caption)
    }

    private func submit(rating: Int) {
        vm.submitFeedback(topicIndex: index, rating: rating, comment: comment)
        comment = ""
    }

    private var priorityChip: some View {
        Text(topic.priority.isEmpty ? "medium" : topic.priority)
            .font(.caption2)
            .foregroundStyle(priorityColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor.opacity(0.12), in: Capsule())
    }

    private var priorityColor: Color {
        switch topic.priority {
        case "high": .red
        case "low": .blue
        default: .orange
        }
    }
}
