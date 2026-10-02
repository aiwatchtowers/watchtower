import SwiftUI
import WatchtowerCore

/// What a row can ask of the thread. Closures are rebuilt per render and are
/// deliberately excluded from `ChatMessageRow`'s equality. A nil action hides
/// its button: the embedded chats offer Copy and Retry only (`embedded`).
struct ChatRowActions {
    var copy: (String) -> Void = { _ in }
    var regenerate: ((Int64) -> Void)? = { _ in }
    var retry: ((Int64) -> Void)? = { _ in }
    var continueStopped: ((Int64) -> Void)? = { _ in }
    var showVariant: ((Int64, Int) -> Void)? = { _, _ in }
    var beginEdit: ((Int64) -> Void)? = { _ in }
    var submitEdit: (Int64, String) -> Void = { _, _ in }
    var cancelEdit: () -> Void = {}
    var openArtifact: (String) -> Void = { _ in }
    var openSources: (Int64, [ChatSource]) -> Void = { _, _ in }
    var quote: ((Int64, String) -> Void)? = { _, _ in }
    /// Sends a question card's answers as the owner's next message; nil
    /// while the card cannot be answered (an older reply, a turn running).
    var answerQuestion: ((String) -> Void)?

    /// An embedded chat's row: Copy always, Retry only where the caller
    /// passes one (the last failed reply), answering a question card only on
    /// the latest reply.
    static func embedded(
        copy: @escaping (String) -> Void,
        retry: ((Int64) -> Void)?,
        answerQuestion: ((String) -> Void)? = nil
    ) -> Self {
        Self(copy: copy, regenerate: nil, retry: retry, continueStopped: nil, showVariant: nil,
             beginEdit: nil, quote: nil, answerQuestion: answerQuestion)
    }
}

/// A finished message. `Equatable` on its data only + `.equatable()` at the
/// call site: an unchanged row never re-renders its markdown (render isolation).
struct ChatMessageRow: View, Equatable {
    let item: ChatThreadItem
    let isLast: Bool
    let isEditing: Bool
    let actions: ChatRowActions
    var artifactVersions: [String: Int] = [:]
    /// The owner message that followed this reply — answers a question card.
    var questionAnswer: String?
    @State private var hovering = false
    @State private var editText = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.isLast == rhs.isLast && lhs.isEditing == rhs.isEditing
            && lhs.artifactVersions == rhs.artifactVersions
            // Retry comes and goes on an embedded chat's failed reply (it
            // hides while a turn runs or waits): its presence is data.
            && (lhs.actions.retry == nil) == (rhs.actions.retry == nil)
            && lhs.questionAnswer == rhs.questionAnswer
            && (lhs.actions.answerQuestion == nil) == (rhs.actions.answerQuestion == nil)
    }

    var body: some View {
        VStack(alignment: item.message.isUser ? .trailing : .leading, spacing: 4) {
            content
            if !item.message.isAssistant || item.message.status == "complete" {
                actionBar.opacity(hovering || isLast ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        if item.message.isUser {
            if isEditing { editor } else { UserMessageBubble(text: item.message.text, attachments: item.attachments) }
        } else if item.message.isAssistant {
            AssistantMessageBody(text: item.message.text, steps: item.stepDisplays, isRunning: false,
                                 versions: artifactVersions, onOpenArtifact: actions.openArtifact,
                                 onOpenSources: { actions.openSources(item.id, item.sources) },
                                 questionAnswer: questionAnswer, onAnswerQuestion: actions.answerQuestion)
            statusCard
        } else {
            Text(item.message.text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch item.message.status {
        case "error":
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChatErrorPresentation.message(for: item.message.errorCode, provider: item.message.provider))
                        .font(.callout)
                    if let detail = ChatErrorPresentation.detail(item.message.errorMessage) {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if ChatErrorPresentation.isRetryable(item.message.errorCode), let retry = actions.retry {
                    Button("Retry") { retry(item.id) }
                }
            }
            .padding(8)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case "partial":
            HStack(spacing: 8) {
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
                if isLast, let continueStopped = actions.continueStopped {
                    Button("Continue") { continueStopped(item.id) }.controlSize(.small)
                }
            }
        default:
            EmptyView()
        }
    }

    /// The owner's own words, without the skill line/REFERENCED tokens
    /// (Task 25) — what the edit box and the copy button work with for a
    /// user message.
    private var userDisplayBody: String { ChatTurnComposer.displayParts(item.message.text).body }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $editText)
                .frame(minHeight: 60, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Cancel", role: .cancel) { actions.cancelEdit() }
                Button("Save & Send") { actions.submitEdit(item.id, editText) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { editText = userDisplayBody }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { actions.copy(item.message.isUser ? userDisplayBody : item.message.text) }
                label: { Image(systemName: "doc.on.doc") }
                .help("Copy message")
                .accessibilityLabel("Copy message")
            if item.message.isUser, let beginEdit = actions.beginEdit {
                Button { beginEdit(item.id) } label: { Image(systemName: "pencil") }
                    .help("Edit")
                    .accessibilityLabel("Edit")
            } else if item.message.isAssistant {
                if let quote = actions.quote {
                    Button { quote(item.id, item.message.text) } label: { Image(systemName: "text.quote") }
                        .help("Quote in reply")
                        .accessibilityLabel("Quote in reply")
                }
                if let regenerate = actions.regenerate {
                    Button { regenerate(item.id) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Regenerate")
                        .accessibilityLabel("Regenerate")
                }
            }
            if item.siblingCount > 1, let showVariant = actions.showVariant {
                Button { showVariant(item.id, -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(item.siblingIndex <= 1)
                    .help("Previous version")
                    .accessibilityLabel("Previous version")
                Text("\(item.siblingIndex)/\(item.siblingCount)").font(.caption).monospacedDigit()
                Button { showVariant(item.id, 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(item.siblingIndex >= item.siblingCount)
                    .help("Next version")
                    .accessibilityLabel("Next version")
            }
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var caption: String {
        let time = item.message.createdDate.formatted(date: .omitted, time: .shortened)
        guard let model = item.message.model, !model.isEmpty else { return time }
        return "\(model) · \(time)"
    }
}

/// The streaming message: the only view that reads `LiveTurn.text`, so only
/// it re-renders on a delta — and so it is also the only place that can
/// observe the stream for artifact blocks without re-rendering the rest of
/// the thread (preflight A33/A38: "the live panel observes `liveTurn.text`
/// in the view" — there is no per-delta hook on `ChatViewModel` itself,
/// deltas go straight from the pool into `LiveTurn`).
struct LiveAssistantRow: View {
    let turn: LiveTurn
    var onOpenArtifact: (String) -> Void = { _ in }
    var onOpenSources: ([ChatSource]) -> Void = { _ in }
    var onStreamingTextChanged: (String) -> Void = { _ in }

    var body: some View {
        // Labelled: the question-card closures follow onOpenSources.
        // swiftlint:disable trailing_closure
        AssistantMessageBody(text: turn.text, steps: turn.steps, isRunning: turn.isRunning,
                             onOpenArtifact: onOpenArtifact,
                             onOpenSources: { onOpenSources(turn.steps.flatMap(\.sources)) })
        // swiftlint:enable trailing_closure
            .onChange(of: turn.text, initial: true) { _, newValue in onStreamingTextChanged(newValue) }
    }
}

/// Steps → text/artifact cards → sources (spec §3.2, §7.2). The sources row
/// appears only once the turn is finished (complete/partial) — while it
/// streams, the steps block is the only progress surface. `:::artifact`
/// blocks in the text render as `ArtifactCardView` cards instead of markdown
/// (Task 22's `ArtifactParser`); `isRunning` decides whether an in-progress
/// block shows "Writing …" and `final: false` parsing (a still-open fence
/// stays an incomplete draft rather than literal text).
struct AssistantMessageBody: View {
    let text: String
    let steps: [ChatStepDisplay]
    let isRunning: Bool
    var versions: [String: Int] = [:]
    var onOpenArtifact: (String) -> Void = { _ in }
    var onOpenSources: () -> Void = {}
    /// A question card's answer (the next owner message) and its sender.
    var questionAnswer: String?
    var onAnswerQuestion: ((String) -> Void)?

    var body: some View {
        // A question card leaves the text; while streaming its open block is
        // hidden (ChatQuestionParser).
        let question = ChatQuestionParser.parse(text, final: !isRunning)
        VStack(alignment: .leading, spacing: 8) {
            StepsBlockView(steps: steps, isRunning: isRunning)
            if question.text.isEmpty && isRunning {
                StreamingIndicator()
            } else {
                let parsed = ArtifactParser.parse(question.text, final: !isRunning)
                ForEach(Array(parsed.segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        MarkdownView(text: markdown)
                    case .artifact(let draft):
                        ArtifactCardView(draft: draft, isWriting: isRunning && !draft.isComplete,
                                         version: versions[draft.key]) { onOpenArtifact(draft.key) }
                    }
                }
            }
            if let card = question.card {
                ChatQuestionCardView(card: card, answerText: questionAnswer, onAnswer: onAnswerQuestion)
            }
            if !isRunning {
                SourcesSummaryRow(sources: steps.flatMap(\.sources), onOpen: onOpenSources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders the stored owner text split into its skill/reference chips (Task
/// 25/26's `ChatTurnComposer`) plus the plain body — never the raw stored
/// text, which would otherwise leak the `Use skill …`/`REFERENCED: …` lines
/// into the bubble.
struct UserMessageBubble: View {
    let text: String
    var attachments: [ChatAttachment] = []

    private var parts: ChatTurnDisplayParts { ChatTurnComposer.displayParts(text) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: nil)
            }
            if parts.skill != nil || !parts.references.isEmpty {
                HStack(spacing: 4) {
                    if let skill = parts.skill {
                        Label("/" + skill, systemImage: "wand.and.stars").font(.caption2)
                    }
                    ForEach(parts.references, id: \.token) { ref in
                        Text("@" + ref.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer(minLength: 40)
                Text(parts.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
