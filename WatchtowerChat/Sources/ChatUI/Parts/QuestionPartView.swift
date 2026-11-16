import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

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
    @State private var picks: [String: ChatQuestionAnswer.Entry] = [:]
    @Environment(\.chatUIStyle) private var style

    /// `answerText` is the owner's message right after the reply (nil while unanswered); `onAnswer` nil makes the
    /// card read-only (not the latest reply, or a turn runs).
    public init(card: ChatQuestionCard, answerText: String?, onAnswer: ((String) -> Void)?) {
        self.card = card
        self.answerText = answerText
        self.onAnswer = onAnswer
    }

    private var answered: [String: ChatQuestionAnswer.Entry]? {
        answerText.map { ChatQuestionAnswer.selections(in: $0, for: card) }
    }

    private var interactive: Bool { answerText == nil && onAnswer != nil }

    /// Every question has a pick or an answer of its own.
    static func isComplete(_ card: ChatQuestionCard, picks: [String: ChatQuestionAnswer.Entry]) -> Bool {
        card.questions.allSatisfy { !(picks[$0.id] ?? .init()).isEmpty }
    }

    public var body: some View {
        style.card {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(card.questions) { question in
                    questionView(question)
                }
                footer
            }
        }
        .accessibilityIdentifier("chat.question")
    }

    private func questionView(_ question: ChatQuestion) -> some View {
        let entry = answered?[question.id] ?? picks[question.id] ?? .init()
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(Self.inline(question.question)).font(.callout.weight(.semibold))
            ForEach(question.options, id: \.label) { option in
                optionRow(option, in: question, selected: entry.labels.contains(option.label))
            }
            if interactive {
                TextField(Self.otherPlaceholder, text: otherBinding(question), axis: .vertical)
                    .lineLimit(1...4)
                    .font(.callout)
            } else if let other = entry.other, !other.isEmpty {
                Text("Other: \(other)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func optionRow(_ option: ChatQuestionOption, in question: ChatQuestion, selected: Bool) -> some View {
        let icon = Self.icon(multi: question.multi, selected: selected)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            Button {
                picks[question.id] = (picks[question.id] ?? .init()).toggling(option.label, multi: question.multi)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: icon).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(Self.inline(option.label))
                    if option.recommended {
                        style.chip(Self.recommendedLabel)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
            if !option.description.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: icon).hidden().accessibilityHidden(true)
                    Text(Self.inline(option.description)).font(.caption).foregroundStyle(.secondary)
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
                picks[question.id] = entry
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
