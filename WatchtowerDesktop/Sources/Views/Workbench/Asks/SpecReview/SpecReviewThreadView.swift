import SwiftUI
import WatchtowerCore

/// One row of a Discuss thread, in the order it happened (spec 2026-11-08
/// §3): the owner's words, the assistant's replies, a question the
/// assistant put to the author, a finding it proposes, a line from
/// Watchtower, and a reply that failed.
enum SpecReviewThreadEntry: Identifiable {
    case owner(id: String, text: String)
    case assistant(id: String, text: String)
    case question(SpecReviewQuestionRow)
    case finding(id: String, SpecReviewProposedFinding)
    case notice(id: String, text: String)
    /// The embedded chat's error card: what went wrong, the provider's own
    /// text, and Retry on the last failed reply while nothing runs.
    case failed(id: String, message: String, detail: String?, canRetry: Bool)

    var id: String {
        switch self {
        case let .owner(id, _), let .assistant(id, _), let .finding(id, _), let .notice(id, _): id
        case let .failed(id, _, _, _): id
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
    /// The owner's and the assistant's finished messages on disk, for the
    /// folded line of a thread not loaded in this screen yet.
    var persistedMessageCount = 0
    /// The owner's message waits for a free slot (3 embedded turns at once).
    var isQueued = false
    /// The thread is being opened (its conversation and the reviewer's data).
    var isOpening = false
    /// Opening the thread failed; **Retry** opens it again.
    var loadError: String?

    /// "thread · N": the owner's and the assistant's messages.
    var messageCount: Int {
        let loaded = entries.filter {
            switch $0 {
            case .owner, .assistant: true
            case .question, .finding, .notice, .failed: false
            }
        }.count
        return entries.isEmpty ? persistedMessageCount : loaded
    }
}

/// The Discuss threads a spec review screen can show, set on its
/// environment. Nil: the screen has no threads — **Discuss** is not
/// offered and **Comment** stays where it was.
struct SpecReviewThreads {
    /// An item's thread by key; an empty one when none was started.
    let thread: (String) -> SpecReviewThreadContent
    /// False when the thread did not take the message (it stays in the
    /// composer).
    var send: (_ key: String, _ text: String) -> Bool = { _, _ in true }
    var addToReview: (_ key: String, _ finding: SpecReviewProposedFinding) -> Void = { _, _ in }
    /// **Discuss** or the folded line: the thread opens (its conversation,
    /// the reviewer's data); again after a failure.
    var open: (_ key: String) -> Void = { _ in }
    /// **Hide**: the thread folds; a reply in flight keeps going.
    var hide: (_ key: String) -> Void = { _ in }
    var retry: (_ key: String) -> Void = { _ in }
    var stop: (_ key: String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var specReviewThreads: SpecReviewThreads?
}

/// Whether a card shows its thread: as the thread itself says (open when
/// it was left open), or as the owner set it — **Discuss** (the composer
/// takes the focus), the folded line, **Hide**.
enum SpecReviewThreadVisibility {
    case auto, shown, discussed, hidden

    /// The owner asked for it: open it.
    var isRequested: Bool { self == .shown || self == .discussed }
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
            Group {
                if visibility.isRequested || (visibility == .auto && content.isOpen) {
                    SpecReviewThreadView(
                        content: content,
                        placeholder: placeholder,
                        autoFocus: visibility == .discussed,
                        onSend: { threads.send(key, $0) },
                        onAddToReview: { threads.addToReview(key, $0) },
                        onHide: {
                            visibility = .hidden
                            threads.hide(key)
                        },
                        onRetry: { threads.retry(key) },
                        onStop: { threads.stop(key) },
                        onReopen: { threads.open(key) }
                    )
                } else if content.messageCount > 0 {
                    SpecReviewThreadFoldedLine(count: content.messageCount) { visibility = .shown }
                }
            }
            .onChange(of: visibility) { _, new in
                if new.isRequested { threads.open(key) }
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
    /// The composer takes the focus: on an explicit **Discuss** press only.
    var autoFocus = false
    let onSend: (String) -> Bool
    let onAddToReview: (SpecReviewProposedFinding) -> Void
    let onHide: () -> Void
    var onRetry: () -> Void = {}
    var onStop: () -> Void = {}
    /// Opens a thread whose opening failed again.
    var onReopen: () -> Void = {}
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
            if let error = content.loadError {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.regular)
                    Button("Retry", action: onReopen).buttonStyle(.kitSecondary).controlSize(.small)
                }
            } else if content.isOpening {
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.mini)
                    Text("Opening the discussion…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if content.isQueued {
                Text("Queued: other chats are replying. It starts when one finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if content.isReplying {
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.mini)
                    Text("The assistant is replying…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !content.isOrphaned {
                ChatComposerField(
                    text: $draft,
                    isStreaming: content.isReplying || content.isQueued,
                    onSend: send,
                    onStop: onStop,
                    placeholder: placeholder,
                    autoFocus: autoFocus
                )
                .disabled(content.isOpening || content.loadError != nil)
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
        case let .notice(_, text):
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case let .failed(_, message, detail, canRetry):
            HStack(alignment: .top, spacing: Spacing.compact) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.error)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: Spacing.regular)
                if canRetry {
                    Button("Retry", action: onRetry).buttonStyle(.kitSecondary).controlSize(.small)
                }
            }
            .padding(Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !content.isReplying, !content.isQueued else { return }
        if onSend(text) { draft = "" }
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
