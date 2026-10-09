import Foundation

extension OwnerAskAnswer {
    /// A structured answer (the phone's, mobile POC spec §6.2) as it would
    /// be stored: text trimmed, and each check item it leaves out marked
    /// `skipped` after the ones it marks, as a draft leaves unmarked items
    /// (`OwnerAskDraft.answer`). Nothing else changes, so `problem` then
    /// applies the rules `OwnerAskDraft.isAnswerable` applies — a verdict
    /// for a review, a label or an Other for every question, labels among
    /// the options, known check items, non-empty comment bodies — and a
    /// blank comment is refused, not dropped. Likewise a verdict or comments
    /// on an ask that is not a review are refused (`verdictNotAllowed`,
    /// `commentsNotAllowed`), where a draft silently drops them. A draft's
    /// answer comes back unchanged. Pure.
    package func normalized(for ask: OwnerAsk) -> OwnerAskAnswer {
        let marked = Set(checklist.map(\.id))
        return OwnerAskAnswer(
            verdict: verdict,
            answers: answers.map { .init(id: $0.id, labels: $0.labels, other: Self.trimmed($0.other)) },
            checklist: checklist.map { .init(id: $0.id, state: $0.state, note: Self.trimmed($0.note)) }
                + ask.payload.checklist.filter { !marked.contains($0.id) }.map { .init(id: $0.id, state: .skipped) },
            comments: comments.map { comment in
                var trimmed = comment
                trimmed.body = Self.trimmed(comment.body)
                return trimmed
            },
            note: Self.trimmed(note)
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
