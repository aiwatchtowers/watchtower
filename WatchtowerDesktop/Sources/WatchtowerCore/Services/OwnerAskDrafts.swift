import Foundation
import Observation

/// One unsent review comment: the passage of the ask's `doc_snapshot` it
/// anchors on and the owner's text.
package struct OwnerAskCommentDraft: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let anchor: CommentAnchor
    package var body: String

    package init(id: UUID = UUID(), anchor: CommentAnchor, body: String) {
        self.id = id
        self.anchor = anchor
        self.body = body
    }
}

/// The owner's unfinished answer to one ask: picks, check marks, margin
/// comments, the verdict and the note. Pure.
package struct OwnerAskDraft: Equatable, Sendable {
    package var verdict: OwnerAskAnswer.Verdict?
    /// Question id → the picked labels and the free "Other".
    package var picks: [String: ChatQuestionAnswer.Entry] = [:]
    /// Check item id → its mark; an item without one is `skipped`.
    package var checks: [String: OwnerAskAnswer.CheckState] = [:]
    package var checkNotes: [String: String] = [:]
    package var comments: [OwnerAskCommentDraft] = []
    package var note = ""

    package init() {}

    /// Nothing the owner would lose: no pick, mark, verdict or text.
    package var isEmpty: Bool {
        verdict == nil
            && picks.values.allSatisfy(\.isEmpty)
            && checks.isEmpty
            && checkNotes.values.allSatisfy { Self.trimmed($0).isEmpty }
            && comments.allSatisfy { Self.trimmed($0.body).isEmpty }
            && Self.trimmed(note).isEmpty
    }

    /// Whether Go's reader will take the answer this draft gives: every
    /// question picked, a review's verdict, a note on each broken item, the
    /// note within its bound. A check may leave items unmarked (they go as
    /// skipped; spec 2026-10-03 Parts 3 and 8).
    package func isAnswerable(for ask: OwnerAsk) -> Bool {
        problem(for: ask) == nil
    }

    /// The first thing Go's reader would refuse in the answer this draft
    /// gives (`OwnerAskAnswer.problem`); nil when it can be sent.
    package func problem(for ask: OwnerAsk) -> OwnerAskAnswerProblem? {
        answer(for: ask).problem(kind: ask.kind, payload: ask.payload)
    }

    /// The answer as stored: questions and check items in the payload's
    /// order, unmarked items `skipped`, empty comments (and any on a kind
    /// other than a review) dropped, text trimmed.
    package func answer(for ask: OwnerAsk) -> OwnerAskAnswer {
        OwnerAskAnswer(
            verdict: ask.kind == .review ? verdict : nil,
            answers: ask.payload.questions.map { question in
                let entry = picks[question.id] ?? .init()
                return .init(id: question.id, labels: entry.labels, other: Self.trimmed(entry.other ?? ""))
            },
            checklist: ask.payload.checklist.map { item in
                .init(id: item.id, state: checks[item.id] ?? .skipped, note: Self.trimmed(checkNotes[item.id] ?? ""))
            },
            // Only a review has comments.
            comments: ask.kind != .review ? [] : comments.compactMap { draft in
                let body = Self.trimmed(draft.body)
                return body.isEmpty ? nil : .init(anchor: draft.anchor, body: body)
            },
            note: Self.trimmed(note)
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The owner's unsent answers, per ask id. Owned by `OwnerAsksViewModel`
/// (AppState), so drafts survive switching sessions, workbenches and tabs;
/// they live in memory only and are never written to the DB — answering is
/// what persists them, and quitting with drafts asks first.
@MainActor @Observable
package final class OwnerAskDrafts {
    package private(set) var byAsk: [Int64: OwnerAskDraft] = [:]

    package nonisolated init() {}

    /// Asks with something the owner would lose.
    package var count: Int { byAsk.values.filter { !$0.isEmpty }.count }

    package func draft(for askID: Int64) -> OwnerAskDraft {
        byAsk[askID] ?? OwnerAskDraft()
    }

    package func update(_ askID: Int64, _ change: (inout OwnerAskDraft) -> Void) {
        var draft = draft(for: askID)
        change(&draft)
        // Kept even while empty: a comment just anchored has no text yet.
        byAsk[askID] = draft
    }

    package func discard(_ askID: Int64) {
        byAsk[askID] = nil
    }
}
