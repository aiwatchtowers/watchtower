import Foundation

/// What the ask views show (spec 2026-10-03 Part 8): the answer bar's
/// buttons and when they act, the check summary, the drawer's "k of N", a
/// closed ask's status. Pure.
package enum OwnerAskPresentation {
    /// One answer button. A review's two carry the verdict they answer with.
    package struct AnswerAction: Equatable, Sendable {
        package let label: String
        package let verdict: OwnerAskAnswer.Verdict?
        package let isPrimary: Bool

        package init(label: String, verdict: OwnerAskAnswer.Verdict?, isPrimary: Bool) {
            self.label = label
            self.verdict = verdict
            self.isPrimary = isPrimary
        }
    }

    package static func answerActions(for kind: OwnerAskKind) -> [AnswerAction] {
        switch kind {
        case .review:
            [AnswerAction(label: "Request changes", verdict: .changes, isPrimary: false),
             AnswerAction(label: "Approve", verdict: .approved, isPrimary: true)]
        case .check: [AnswerAction(label: "Send", verdict: nil, isPrimary: true)]
        case .question: [AnswerAction(label: "Answer", verdict: nil, isPrimary: true)]
        }
    }

    /// Whether `action` may answer `ask` from `draft` now: the ask still
    /// open, no answer being written, every question picked and — with the
    /// button's verdict — a review's verdict given. A check answers with
    /// items left unmarked.
    package static func canAnswer(_ ask: OwnerAsk, draft: OwnerAskDraft, with action: AnswerAction, answering: Bool) -> Bool {
        guard ask.isOpen, !answering else { return false }
        var draft = draft
        if let verdict = action.verdict { draft.verdict = verdict }
        return draft.isAnswerable(for: ask)
    }

    /// "1 ok · 1 broken · 1 unmarked": the marks of the payload's items,
    /// empty counts left out.
    package static func checkSummary(_ items: [OwnerAskCheckItem], marks: [String: OwnerAskAnswer.CheckState]) -> String {
        let states = items.map { marks[$0.id] }
        let parts: [(Int, String)] = [
            (states.filter { $0 == .ok }.count, "ok"),
            (states.filter { $0 == .broken }.count, "broken"),
            (states.filter { $0 == .skipped }.count, "skipped"),
            (states.filter { $0 == nil }.count, "unmarked")
        ]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// The drawer's place in the stack, "k of N".
    package static func positionLabel(_ position: Int, of count: Int) -> String {
        "\(position) of \(count)"
    }

    /// What became of an ask; a superseded one names the round that replaced
    /// it (`OwnerAskQueries.replacements`).
    package static func statusLine(_ ask: OwnerAsk, replacedBy: Int64?) -> String {
        switch ask.status {
        case .open: "Waiting for you"
        case .answered: "Answered"
        case .delivered: "Delivered"
        case .withdrawn:
            if ask.withdrawnReason == "superseded" {
                replacedBy.map { "replaced by #\($0)" } ?? "replaced by a newer ask"
            } else {
                "withdrawn by the agent"
            }
        }
    }

    package static func kindIcon(_ kind: OwnerAskKind) -> String {
        switch kind {
        case .review: "doc.text.magnifyingglass"
        case .check: "checklist"
        case .question: "questionmark.bubble"
        }
    }

    package static func kindLabel(_ kind: OwnerAskKind) -> String {
        switch kind {
        case .review: "Review"
        case .check: "Check"
        case .question: "Question"
        }
    }

    /// A stored answer's question picks, as the question card shows them.
    package static func picks(from answer: OwnerAskAnswer) -> [String: ChatQuestionAnswer.Entry] {
        Dictionary(answer.answers.map { ($0.id, .init(labels: $0.labels, other: $0.other.isEmpty ? nil : $0.other)) }) { first, _ in first }
    }

    /// A stored answer's check marks.
    package static func marks(from answer: OwnerAskAnswer) -> [String: OwnerAskAnswer.CheckState] {
        Dictionary(answer.checklist.map { ($0.id, $0.state) }) { first, _ in first }
    }

    /// A stored answer's notes on check items, the empty ones left out.
    package static func notes(from answer: OwnerAskAnswer) -> [String: String] {
        Dictionary(answer.checklist.filter { !$0.note.isEmpty }.map { ($0.id, $0.note) }) { first, _ in first }
    }
}
