import Foundation
import Observation
import WatchtowerKit

/// One unsent review comment: the passage of the snapshot it anchors on and
/// the owner's text.
struct AskCommentDraft: Identifiable, Equatable {
    let id: UUID
    let anchor: CommentAnchorBuilder.Anchor
    var body: String

    init(id: UUID = UUID(), anchor: CommentAnchorBuilder.Anchor, body: String = "") {
        self.id = id
        self.anchor = anchor
        self.body = body
    }
}

/// The picked labels and the free "Other" of one question.
struct AskQuestionPick: Equatable {
    var labels: [String] = []
    var other = ""
}

/// The owner's unfinished answer to one ask on the phone: the twin of
/// Core's `OwnerAskDraft`, with the Mac's validation rules (spec §6.2) so
/// Send stays off until the Mac would take the answer. The Mac re-validates.
struct AskDraft: Equatable {
    /// Go's `asks.Answer.note` bound, in runes.
    static let noteLimit = 4_000

    var verdict: OwnerAskAnswer.Verdict?
    /// Question id → its picks.
    var picks: [String: AskQuestionPick] = [:]
    /// Check item id → its mark; an item without one goes as `skipped`.
    var checks: [String: OwnerAskAnswer.CheckState] = [:]
    var checkNotes: [String: String] = [:]
    var comments: [AskCommentDraft] = []
    var note = ""

    /// The answer as the Mac stores it: questions and check items in the
    /// payload's order, unmarked items `skipped`, comments without text (and
    /// any on a kind other than a review) dropped, text trimmed. nil when
    /// the ask has no payload on the phone.
    func answer(for ask: OwnerAsk) -> OwnerAskAnswer? {
        guard let payload = ask.payload else { return nil }
        let review = ask.kind == .review
        return OwnerAskAnswer(
            verdict: review ? verdict : nil,
            answers: payload.questions.map { question in
                let pick = picks[question.id] ?? AskQuestionPick()
                return .init(id: question.id, labels: pick.labels, other: Self.trimmed(pick.other))
            },
            checklist: payload.checklist.map { item in
                .init(id: item.id, state: checks[item.id] ?? .skipped, note: Self.trimmed(checkNotes[item.id] ?? ""))
            },
            comments: review ? comments.compactMap { draft in
                let body = Self.trimmed(draft.body)
                return body.isEmpty ? nil : OwnerAskAnswer.Comment(anchor: draft.anchor, body: body)
            } : [],
            note: Self.trimmed(note)
        )
    }

    /// Whether the Mac will take this answer: a review's verdict; every
    /// question a label from its options (one unless multi) or an Other
    /// that is not just whitespace; a note on every broken item; the note
    /// within its bound.
    func isAnswerable(for ask: OwnerAsk) -> Bool {
        guard let payload = ask.payload, let answer = answer(for: ask) else { return false }
        if ask.kind == .review && answer.verdict == nil { return false }
        if answer.note.unicodeScalars.count > Self.noteLimit { return false }
        if answer.checklist.contains(where: { $0.state == .broken && $0.note.isEmpty }) { return false }
        return zip(payload.questions, answer.answers).allSatisfy { question, answer in
            Self.isAnswered(question, answer)
        }
    }

    /// Whether one question's pick counts as an answer.
    static func isAnswered(_ question: OwnerAskPayload.Question, _ answer: OwnerAskAnswer.QuestionAnswer) -> Bool {
        if answer.labels.isEmpty && answer.other.isEmpty { return false }
        if !question.multi && answer.labels.count > 1 { return false }
        return answer.labels.allSatisfy { label in question.options.contains { $0.label == label } }
    }

    /// The draft's free text (Other answers, comments, check notes, the
    /// note), kept as one text when the ask it was for is replaced: labels
    /// and anchors do not carry over to another ask.
    func freeText(for ask: OwnerAsk) -> String {
        var parts: [String] = []
        for question in ask.payload?.questions ?? [] {
            let other = Self.trimmed(picks[question.id]?.other ?? "")
            if !other.isEmpty { parts.append(other) }
        }
        for comment in comments {
            let body = Self.trimmed(comment.body)
            if !body.isEmpty { parts.append("“\(comment.anchor.quote)” — \(body)") }
        }
        for item in ask.payload?.checklist ?? [] {
            let note = Self.trimmed(checkNotes[item.id] ?? "")
            if !note.isEmpty { parts.append("\(item.text): \(note)") }
        }
        let note = Self.trimmed(note)
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "\n\n")
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The owner's unsent answers, per ask id. Owned by `AppEnvironment`, so a
/// draft survives leaving and reopening its ask; in memory only. A
/// successful answer (`applied`) clears it.
@MainActor
@Observable
final class AskDraftStore {
    private(set) var byAsk: [Int64: AskDraft] = [:]

    func draft(for askID: Int64) -> AskDraft {
        byAsk[askID] ?? AskDraft()
    }

    func update(_ askID: Int64, _ change: (inout AskDraft) -> Void) {
        var draft = draft(for: askID)
        change(&draft)
        byAsk[askID] = draft
    }

    func discard(_ askID: Int64) {
        byAsk[askID] = nil
    }
}
