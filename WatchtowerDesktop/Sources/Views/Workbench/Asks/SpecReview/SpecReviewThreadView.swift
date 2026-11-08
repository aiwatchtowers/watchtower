import SwiftUI
import WatchtowerCore

/// One row of a Discuss thread, in the order it happened (spec 2026-11-08
/// §3): the owner's words, the assistant's replies, a question the
/// assistant put to the author, and a finding it proposes.
enum SpecReviewThreadEntry: Identifiable {
    case owner(id: String, text: String)
    case assistant(id: String, text: String)
    case question(SpecReviewQuestionRow)
    case finding(id: String, SpecReviewProposedFinding)

    var id: String {
        switch self {
        case let .owner(id, _), let .assistant(id, _), let .finding(id, _): id
        case let .question(row): "question:\(row.id)"
        }
    }
}

/// What one item's thread holds.
struct SpecReviewThreadContent {
    var entries: [SpecReviewThreadEntry] = []
    /// The assistant is writing its next reply.
    var isReplying = false
    /// Drawn open (an open thread survives closing the drawer).
    var isOpen = false
    /// The item is gone after a re-run: "from the previous run", readable
    /// only.
    var isOrphaned = false

    /// "thread · N": the owner's and the assistant's messages.
    var messageCount: Int {
        entries.filter {
            switch $0 {
            case .owner, .assistant: true
            case .question, .finding: false
            }
        }.count
    }
}

/// The Discuss threads a spec review screen can show, set on its
/// environment. Nil: the screen has no threads — **Discuss** is not
/// offered and **Comment** stays where it was.
struct SpecReviewThreads {
    /// An item's thread by key; an empty one when none was started.
    let thread: (String) -> SpecReviewThreadContent
    var send: (_ key: String, _ text: String) -> Void = { _, _ in }
    var addToReview: (_ key: String, _ finding: SpecReviewProposedFinding) -> Void = { _, _ in }
}

extension EnvironmentValues {
    @Entry var specReviewThreads: SpecReviewThreads?
}

/// Whether a card shows its thread: as the thread itself says (open when
/// it was left open), or as the owner set it with **Discuss** / **Hide**.
enum SpecReviewThreadVisibility {
    case auto, shown, hidden
}

/// A card's thread under its buttons: open, or folded to its "thread · N"
/// line, or nothing when no thread was started.
struct SpecReviewCardThreadSection: View {
    let key: String
    @Binding var visibility: SpecReviewThreadVisibility
    var placeholder = "Ask about this finding"
    @Environment(\.specReviewThreads) private var threads

    var body: some View {
        if let threads {
            let content = threads.thread(key)
            if visibility == .shown || (visibility == .auto && content.isOpen) {
                SpecReviewThreadView(
                    content: content,
                    placeholder: placeholder,
                    onSend: { threads.send(key, $0) },
                    onAddToReview: { threads.addToReview(key, $0) },
                    onHide: { visibility = .hidden }
                )
            } else if content.messageCount > 0 {
                SpecReviewThreadFoldedLine(count: content.messageCount) { visibility = .shown }
            }
        }
    }
}

/// A folded thread: "thread · N", one click opens it.
struct SpecReviewThreadFoldedLine: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label("thread · \(count)", systemImage: "bubble.left.and.bubble.right")
                .font(.caption.monospacedDigit())
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
        .help("Open the discussion")
    }
}

/// A Discuss thread inside a card (spec 2026-11-08 §3): the owner's and
/// the assistant's messages, a question to the author while it waits and
/// once it is answered or not, a proposed finding with **Add to review**,
/// then the composer. The assistant explains and proposes; it never sets a
/// mark — the card's buttons decide.
struct SpecReviewThreadView: View {
    let content: SpecReviewThreadContent
    var placeholder = "Ask about this finding"
    let onSend: (String) -> Void
    let onAddToReview: (SpecReviewProposedFinding) -> Void
    let onHide: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.compact) {
                Label("Discuss", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Hide", action: onHide).buttonStyle(.kitQuiet).controlSize(.small)
            }
            if content.isOrphaned {
                Text("From the previous run: you can read this thread, but it takes no new messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(content.entries) { row($0) }
            if content.isReplying {
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.mini)
                    Text("The assistant is replying…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !content.isOrphaned {
                ChatComposerField(
                    text: $draft,
                    isStreaming: content.isReplying,
                    onSend: send,
                    placeholder: placeholder,
                    autoFocus: true
                )
            }
        }
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    @ViewBuilder
    private func row(_ entry: SpecReviewThreadEntry) -> some View {
        switch entry {
        case let .owner(_, text):
            SpecReviewQuote(label: "You", quote: text, quoted: false)
        case let .assistant(_, text):
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Assistant").font(.caption.weight(.semibold))
                MarkdownView(text: text).font(.callout)
            }
        case let .question(question):
            SpecReviewAuthorQuestionRow(question: question)
        case let .finding(_, finding):
            SpecReviewProposedFindingCard(finding: finding) { onAddToReview(finding) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !content.isReplying else { return }
        draft = ""
        onSend(text)
    }
}

/// A question the assistant put to the author: waiting, answered, or not
/// answered (timed out, or the session ended before it was sent).
struct SpecReviewAuthorQuestionRow: View {
    let question: SpecReviewQuestionRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.compact) {
                if question.state == .open {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.secondary)
                }
                Text(title).font(.caption.weight(.semibold))
            }
            SpecReviewQuote(label: "Question", quote: question.question)
            switch question.state {
            case .answered:
                SpecReviewQuote(label: "Author", quote: question.answer, quoted: false)
            case .expired:
                Text("The author did not answer").font(.caption).foregroundStyle(.secondary)
            case .gone:
                Text("The author's session has ended: the question was not sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unknown:
                Text("This version of the app does not know the question's state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .open:
                EmptyView()
            }
        }
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: String {
        switch question.state {
        case .open: "Asked the author…"
        case .answered: "The author answered"
        case .expired, .gone, .unknown: "Asked the author"
        }
    }
}

/// A finding the assistant proposes: what it is, the quote it rests on,
/// and **Add to review** — nothing is added without that press. Go checks
/// the quotes; a refusal ("not added: quote not found") stays on the card.
struct SpecReviewProposedFindingCard: View {
    let finding: SpecReviewProposedFinding
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                SpecReviewChips(severity: finding.severity, kind: SpecReviewPresentation.proposedBadge(finding))
                Text(finding.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if !finding.text.isEmpty {
                Text(finding.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !finding.quote.text.isEmpty {
                SpecReviewQuote(label: finding.quote.source == "thread" ? "You said in this thread" : "The document says",
                                quote: finding.quote.text)
            }
            if let anchor = finding.anchor, !anchor.quote.isEmpty, anchor.quote != finding.quote.text {
                SpecReviewQuote(label: anchor.heading.isEmpty ? "The document says" : "The document says · \(anchor.heading)",
                                quote: anchor.quote)
            }
            status
        }
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var status: some View {
        switch finding.status {
        case .proposed:
            HStack(spacing: Spacing.regular) {
                Text("Proposed by the assistant: nothing is added until you press it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                Button("Add to review", action: onAdd)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
                    .help("Add it to the review as a new finding")
            }
        case .added:
            Label("Added to the review", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Tone.success)
        case let .refused(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Tone.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
