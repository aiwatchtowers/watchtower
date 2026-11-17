import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// An owner ask's card (the Mac's ask drawer): its picks are the ask's draft (or a closed ask's answer) and the drawer's
/// answer bar sends them, so the card has no footer of its own. The hooks bring the drawer's keyboard in.
public struct ChatQuestionDraft {
    public var picks: Binding<[String: ChatQuestionAnswer.Entry]>
    /// The picks take input (an open ask, no answer being written).
    public var editable: Bool
    /// A question's "Other…" field (the drawer's editor, its keys and focus); nil draws the style's field.
    public var otherField: ((ChatQuestion, Binding<String>) -> AnyView)?
    /// Wraps one question (the drawer's keyboard cursor and its scroll id).
    public var decorate: ((ChatQuestion, AnyView) -> AnyView)?
    /// The help of the option at this index (the digit that picks it).
    public var optionHelp: ((Int) -> String)?

    public init(
        picks: Binding<[String: ChatQuestionAnswer.Entry]>,
        editable: Bool,
        otherField: ((ChatQuestion, Binding<String>) -> AnyView)? = nil,
        decorate: ((ChatQuestion, AnyView) -> AnyView)? = nil,
        optionHelp: ((Int) -> String)? = nil
    ) {
        self.picks = picks
        self.editable = editable
        self.otherField = otherField
        self.decorate = decorate
        self.optionHelp = optionHelp
    }
}

/// A structured question card (the client-derived `question` part, D14): the owner picks options, may type an answer
/// of their own, and the answers go back as their next message (`ChatQuestionAnswer.format`). An answered card reads
/// its selections from that message. Public: embedded chats and the owner-ask drawer draw it too (ruling F19).
public struct QuestionPartView: View {
    public static let sendLabel = "Send answers"
    public static let answeredLabel = "Answered"
    public static let otherPlaceholder = "Other…"
    public static let recommendedLabel = "Recommended"

    let card: ChatQuestionCard
    let answerText: String?
    let onAnswer: ((String) -> Void)?
    let draft: ChatQuestionDraft?
    @State private var ownPicks: [String: ChatQuestionAnswer.Entry] = [:]
    @Environment(\.chatUIStyle) private var style

    /// `answerText` is the owner's message right after the reply (nil while unanswered); `onAnswer` nil makes the
    /// card read-only (not the latest reply, or a turn runs).
    public init(card: ChatQuestionCard, answerText: String?, onAnswer: ((String) -> Void)?) {
        self.card = card
        self.answerText = answerText
        self.onAnswer = onAnswer
        draft = nil
    }

    /// An owner ask's card: the picks are the draft's, and the drawer's bar sends them.
    public init(card: ChatQuestionCard, draft: ChatQuestionDraft) {
        self.card = card
        answerText = nil
        onAnswer = nil
        self.draft = draft
    }

    private var picks: [String: ChatQuestionAnswer.Entry] { draft?.picks.wrappedValue ?? ownPicks }

    private func setPick(_ entry: ChatQuestionAnswer.Entry, for question: ChatQuestion) {
        if let draft {
            draft.picks.wrappedValue[question.id] = entry
        } else {
            ownPicks[question.id] = entry
        }
    }

    private var answered: [String: ChatQuestionAnswer.Entry]? {
        guard draft == nil else { return nil }
        return answerText.map { ChatQuestionAnswer.selections(in: $0, for: card) }
    }

    private var interactive: Bool { draft.map(\.editable) ?? (answerText == nil && onAnswer != nil) }

    /// Every question has a pick or an answer of its own.
    static func isComplete(_ card: ChatQuestionCard, picks: [String: ChatQuestionAnswer.Entry]) -> Bool {
        card.questions.allSatisfy { !(picks[$0.id] ?? .init()).isEmpty }
    }

    public var body: some View {
        style.questionCard(AnyView(
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(card.questions) { question in
                    questionView(question)
                }
                footer
            }
        ))
        .accessibilityIdentifier("chat.question")
    }

    @ViewBuilder
    private func questionView(_ question: ChatQuestion) -> some View {
        if let decorate = draft?.decorate {
            decorate(question, AnyView(questionBody(question)))
        } else {
            questionBody(question)
        }
    }

    private func questionBody(_ question: ChatQuestion) -> some View {
        let entry = answered?[question.id] ?? picks[question.id] ?? .init()
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            QuestionMarkdown(text: question.question).font(.callout.weight(.semibold))
            ForEach(Array(question.options.enumerated()), id: \.element.label) { index, option in
                optionRow(option, in: question, selected: entry.labels.contains(option.label))
                    .help(draft?.optionHelp?(index) ?? "")
            }
            if interactive {
                if let otherField = draft?.otherField {
                    otherField(question, otherBinding(question))
                } else {
                    style.questionOtherField(text: otherBinding(question), placeholder: Self.otherPlaceholder,
                                             onSubmit: draft == nil && onAnswer != nil && Self.isComplete(card, picks: picks)
                                                 ? send : nil)
                }
            } else if let other = entry.other, !other.isEmpty {
                QuestionMarkdown(text: "Other: \(other)", lineBreaks: true).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func send() {
        onAnswer?(ChatQuestionAnswer.format(card, answers: picks))
    }

    private func optionRow(_ option: ChatQuestionOption, in question: ChatQuestion, selected: Bool) -> some View {
        let icon = Self.icon(multi: question.multi, selected: selected)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            Button {
                setPick((picks[question.id] ?? .init()).toggling(option.label, multi: question.multi), for: question)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: icon).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(Self.optionLabel(option.label))
                    if option.recommended {
                        style.recommendedMark(Self.recommendedLabel)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
            .accessibilityLabel(String(Self.optionLabel(option.label).characters))
            if !option.description.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: icon).hidden().accessibilityHidden(true)
                    QuestionMarkdown(text: option.description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if answerText != nil {
            Label(Self.answeredLabel, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else if let onAnswer {
            style.primaryButton(Self.sendLabel) { onAnswer(ChatQuestionAnswer.format(card, answers: picks)) }
                .disabled(!Self.isComplete(card, picks: picks))
                .accessibilityIdentifier("chat.question.send")
        }
    }

    private func otherBinding(_ question: ChatQuestion) -> Binding<String> {
        Binding(
            get: { picks[question.id]?.other ?? "" },
            set: { text in
                var entry = picks[question.id] ?? .init()
                entry.other = text
                if !question.multi && !text.isEmpty { entry.labels = [] }
                setPick(entry, for: question)
            }
        )
    }

    static func icon(multi: Bool, selected: Bool) -> String {
        if multi { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    /// Inline Markdown (bold, code, links) of a label; plain text when it does not parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
