import Foundation

/// A Quick ask's one-tap row on its banner and stack card (spec 2026-10-10
/// Part 9.1–9.2): one button per option — the recommended one(s) first and
/// prominent, the rest in stored order, each option's description as its
/// tooltip — then Reply. A question raised from chat with no options gets
/// Reply only. The answers carry the ask's own question id. Pure.
package struct OwnerAskQuickRow: Equatable, Sendable {
    package struct Choice: Equatable, Sendable {
        package let label: String
        /// The option's description; nil when it has none.
        package let tooltip: String?
        package let isProminent: Bool
    }

    package let questionID: String
    package let choices: [Choice]

    /// Nil when `ask` has no one-tap row — a Full ask, which the banner
    /// opens with Open and the stack card in the drawer. Go stores `quick`
    /// only on one single-choice question; another shape stays Full here.
    package init?(ask: OwnerAsk) {
        guard ask.level == .quick, ask.kind == .question, ask.payload.questions.count == 1,
              let question = ask.payload.questions.first, !question.multi else { return nil }
        questionID = question.id
        let recommended = question.options.filter(\.recommended)
        let others = question.options.filter { !$0.recommended }
        choices = (recommended + others).map { option in
            Choice(label: option.label,
                   tooltip: option.description.isEmpty ? nil : option.description,
                   isProminent: option.recommended)
        }
    }

    /// No option to tap: only Reply.
    package var isReplyOnly: Bool { choices.isEmpty }

    /// Whether the row takes a tap or a Reply: not while an answer to the
    /// ask is being written, and not once one was (the card may outlive
    /// the answer until the list is read again).
    package static func isEnabled(answering: Bool, answered: Bool) -> Bool {
        !answering && !answered
    }

    /// The answer of a tap on `label`.
    package func answer(picking label: String) -> OwnerAskAnswer {
        .quick(label: label, questionID: questionID)
    }

    /// The answer of a Reply; nil when blank — nothing is sent.
    package func reply(_ text: String) -> OwnerAskAnswer? {
        .reply(text, questionID: questionID)
    }
}
