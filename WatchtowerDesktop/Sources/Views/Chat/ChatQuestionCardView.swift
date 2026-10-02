import SwiftUI
import WatchtowerCore

/// A question card from an assistant reply (spec 2026-10-02): each question
/// with its options (radio or checkboxes, a description, a "Recommended"
/// mark) and a free "Other" answer. Send posts the answers as the owner's
/// next message. Once that message exists the card is answered: it shows the
/// choice read back from the message and takes no input.
struct ChatQuestionCardView: View {
    let card: ChatQuestionCard
    /// The owner message that followed the reply, if any.
    let answerText: String?
    /// nil while the card cannot be answered (an older reply, a turn running).
    let onAnswer: ((String) -> Void)?

    @State private var picks: [String: ChatQuestionAnswer.Entry] = [:]

    private var answered: [String: ChatQuestionAnswer.Entry]? {
        answerText.map { ChatQuestionAnswer.selections(in: $0, for: card) }
    }

    private var interactive: Bool { answerText == nil && onAnswer != nil }

    private var complete: Bool {
        card.questions.allSatisfy { !(picks[$0.id] ?? .init()).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(card.questions) { question in
                questionView(question)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
    }

    @ViewBuilder
    private func questionView(_ question: ChatQuestion) -> some View {
        let entry = answered?[question.id] ?? picks[question.id] ?? .init()
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.label) { option in
                optionRow(option, in: question, selected: entry.labels.contains(option.label))
            }
            otherField(question, entry: entry)
        }
    }

    private func optionRow(_ option: ChatQuestionOption, in question: ChatQuestion, selected: Bool) -> some View {
        Button {
            toggle(option.label, in: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(multi: question.multi, selected: selected))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                        if option.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
        .accessibilityLabel(option.label)
    }

    @ViewBuilder
    private func otherField(_ question: ChatQuestion, entry: ChatQuestionAnswer.Entry) -> some View {
        if interactive {
            TextField("Other…", text: otherBinding(question))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        } else if let other = entry.other, !other.isEmpty {
            Text("Other: \(other)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if answerText != nil {
            Label("Answered", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let onAnswer {
            Button("Send answers") {
                onAnswer(ChatQuestionAnswer.format(card, answers: picks))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!complete)
        }
    }

    private func icon(multi: Bool, selected: Bool) -> String {
        if multi { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(_ label: String, in question: ChatQuestion) {
        var entry = picks[question.id] ?? .init()
        if question.multi {
            if let index = entry.labels.firstIndex(of: label) {
                entry.labels.remove(at: index)
            } else {
                entry.labels.append(label)
            }
        } else {
            entry.labels = [label]
            entry.other = nil  // one answer per single-choice question
        }
        picks[question.id] = entry
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
}
