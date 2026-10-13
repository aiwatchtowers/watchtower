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

    /// "N not checked" over a check's Send: the items still unmarked
    /// (they go as Didn't check; it does not block — spec 2026-10-03
    /// Part 3, board #502); nil when there are none or `ask` is no check.
    package static func notChecked(_ ask: OwnerAsk, draft: OwnerAskDraft) -> String? {
        guard ask.kind == .check else { return nil }
        let unmarked = ask.payload.checklist.filter { draft.checks[$0.id] == nil }.count
        return unmarked > 0 ? "\(unmarked) not checked" : nil
    }

    /// A check item's buttons (board #502): what the owner found, with its
    /// SF Symbol; the stored values stay `ok`/`broken`/`skipped`.
    package struct CheckStateOption: Sendable {
        package let state: OwnerAskAnswer.CheckState
        package let label: String
        package let icon: String
    }

    package static let checkStates: [CheckStateOption] = [
        CheckStateOption(state: .ok, label: "Works", icon: "checkmark"),
        CheckStateOption(state: .broken, label: "Doesn't work", icon: "xmark"),
        CheckStateOption(state: .skipped, label: "Didn't check", icon: "minus")
    ]

    /// The answer button a key presses (owner ask #90): ⌘↩ the primary
    /// one — a review's Approve, a check's Send, a question's Answer — and
    /// ⌘⇧↩ (`shift`) a review's Request changes; nil when the key names no
    /// button of `ask`. Never inferred from the draft: whether it can
    /// answer is still `canAnswer`'s.
    package static func keyAction(for ask: OwnerAsk, shift: Bool) -> AnswerAction? {
        answerActions(for: ask.kind).first { $0.isPrimary != shift }
    }

    /// The key that presses `action`, for its button's help.
    package static func keyLabel(_ action: AnswerAction) -> String {
        action.isPrimary ? "⌘↩" : "⌘⇧↩"
    }

    /// Whether `action` may answer `ask` from `draft` now: the ask still
    /// open, no answer being written, and — with the button's verdict — an
    /// answer Go's reader takes (`OwnerAskDraft.problem`). A check answers
    /// with items left unmarked.
    package static func canAnswer(_ ask: OwnerAsk, draft: OwnerAskDraft, with action: AnswerAction, answering: Bool) -> Bool {
        guard ask.isOpen, !answering else { return false }
        var draft = draft
        if let verdict = action.verdict { draft.verdict = verdict }
        return draft.isAnswerable(for: ask)
    }

    /// Why `action` cannot answer an open `ask` from `draft`, in the owner's
    /// words; nil when it can (or the ask is closed).
    package static func blocker(_ ask: OwnerAsk, draft: OwnerAskDraft, with action: AnswerAction) -> String? {
        guard ask.isOpen else { return nil }
        var draft = draft
        if let verdict = action.verdict { draft.verdict = verdict }
        guard let problem = draft.problem(for: ask) else { return nil }
        switch problem {
        case .brokenWithoutNote: return "Say what happened on each item that doesn't work"
        case .noteTooLong: return "Shorten the note to \(OwnerAskAnswerProblem.maxNoteRunes) characters"
        case .questionUnanswered, .emptyQuestionAnswer: return "Answer every question"
        case .verdictRequired: return "Choose Approve or Request changes"
        default: return "This answer cannot be sent: \(problem.message)"
        }
    }

    /// "Works 1 · Doesn't work 1": the marks of the payload's items by
    /// their button labels, empty counts left out; the unmarked ones are
    /// `notChecked`'s.
    package static func checkSummary(_ items: [OwnerAskCheckItem], marks: [String: OwnerAskAnswer.CheckState]) -> String {
        let states = items.compactMap { marks[$0.id] }
        let parts = checkStates.compactMap { option in
            let count = states.filter { $0 == option.state }.count
            return count > 0 ? "\(option.label) \(count)" : nil
        }
        return parts.joined(separator: " · ")
    }

    /// The drawer's place in the stack, "k of N".
    package static func positionLabel(_ position: Int, of count: Int) -> String {
        "\(position) of \(count)"
    }

    /// What became of an ask; a superseded one names the round that replaced
    /// it (`OwnerAskQueries.replacements`).
    package static func askStatusLine(_ ask: OwnerAsk, replacedBy: Int64?) -> String {
        if ask.answer?.dismissed == true { return "Dismissed" }
        return switch ask.status {
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

    /// A "Waiting for you" row's next step (board #366): "Review doc",
    /// "Answer 2 questions", "Run 1 check".
    package static func nextStep(for ask: OwnerAsk) -> String {
        switch ask.kind {
        case .review: "Review doc"
        case .question: counted("Answer", ask.payload.questions.count, "question")
        case .check: counted("Run", ask.payload.checklist.count, "check")
        }
    }

    /// "Answer 1 question", "Answer 3 questions"; the bare verb and plural
    /// noun when there are none (a payload Go would not file).
    private static func counted(_ verb: String, _ count: Int, _ noun: String) -> String {
        switch count {
        case 0: "\(verb) \(noun)s"
        case 1: "\(verb) 1 \(noun)"
        default: "\(verb) \(count) \(noun)s"
        }
    }

    /// The line under the title on an `ask #N` link's hover card (board
    /// #500): "#12 · Check · Waiting for you".
    package static func linkCardDetail(_ ask: OwnerAsk) -> String {
        ["#\(ask.id)", askKindLabel(ask.kind), askStatusLine(ask, replacedBy: nil)].joined(separator: " · ")
    }

    /// The caption of an ask raised from the agent's terminal question
    /// (spec 2026-10-10 Part 9.1): "From chat · 12 min", its age in whole
    /// minutes and "<1 min" under a minute — a stamp ahead of `now` (another
    /// clock) included. Nil when `askedAt` is no `agent_state_at` stamp, as
    /// on an ask the agent filed.
    package static func chatMark(askedAt: String, now: Date) -> String? {
        guard let asked = SessionAgentStatus.parseStamp(askedAt) else { return nil }
        let minutes = Int(now.timeIntervalSince(asked) / 60)
        return minutes < 1 ? "From chat · <1 min" : "From chat · \(minutes) min"
    }

    package static func askKindIcon(_ kind: OwnerAskKind) -> String {
        switch kind {
        case .review: "doc.text.magnifyingglass"
        case .check: "checklist"
        case .question: "questionmark.bubble"
        }
    }

    package static func askKindLabel(_ kind: OwnerAskKind) -> String {
        switch kind {
        case .review: "Review"
        case .check: "Check"
        case .question: "Question"
        }
    }

    /// A stored answer's question picks, as the question card shows them.
    package static func answerPicks(from answer: OwnerAskAnswer) -> [String: ChatQuestionAnswer.Entry] {
        Dictionary(answer.answers.map { ($0.id, .init(labels: $0.labels, other: $0.other.isEmpty ? nil : $0.other)) }) { first, _ in first }
    }

    /// A stored answer's check marks.
    package static func answerMarks(from answer: OwnerAskAnswer) -> [String: OwnerAskAnswer.CheckState] {
        Dictionary(answer.checklist.map { ($0.id, $0.state) }) { first, _ in first }
    }

    /// A stored answer's notes on check items, the empty ones left out.
    package static func answerNotes(from answer: OwnerAskAnswer) -> [String: String] {
        Dictionary(answer.checklist.filter { !$0.note.isEmpty }.map { ($0.id, $0.note) }) { first, _ in first }
    }
}
