import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// One open ask screen: which ask and question page it shows, and the
/// owner's edits, written straight into the ask's draft in `AskDraftStore`
/// (so they survive leaving the screen). Sends through `AskAnswerer`.
///
/// Superseded (spec §9, Review Focus 3): when the answer fails
/// `ask_not_open` and a newer round of the ask is open (`previous_ask_id`
/// chain), `followSuccessor` moves the screen to it and keeps the old
/// draft's free text in the new draft's note; labels and anchors do not
/// carry over.
@MainActor
@Observable
final class AskViewModel {
    private(set) var askID: Int64
    private(set) var page = 0
    /// Why the last Send could not be queued at all (not linked, a save
    /// error); cleared by the next Send.
    private(set) var sendError: String?
    /// Set once the screen moved to a newer round.
    private(set) var carriedNotice: String?

    @ObservationIgnored private let drafts: AskDraftStore
    @ObservationIgnored private let answerer: AskAnswerer

    init(askID: Int64, drafts: AskDraftStore, answerer: AskAnswerer) {
        self.askID = askID
        self.drafts = drafts
        self.answerer = answerer
    }

    var draft: AskDraft { drafts.draft(for: askID) }

    func form(snapshot: WorkbenchReplicaSnapshot, now: Date) -> AskFormModel? {
        AskFormModel(
            askID: askID,
            snapshot: snapshot,
            draft: draft,
            page: page,
            now: now,
            applied: answerer.applied[askID],
            isSending: answerer.isSending(askID)
        )
    }

    // MARK: - Questions

    /// A tap on an option: a single-select question takes it (or drops it
    /// when picked), a multi-select one toggles it.
    func pick(_ label: String, in question: AskFormModel.QuestionPage) {
        drafts.update(askID) { draft in
            var pick = draft.picks[question.questionID] ?? AskQuestionPick()
            if pick.labels.contains(label) {
                pick.labels.removeAll { $0 == label }
            } else {
                pick.labels = question.multi ? pick.labels + [label] : [label]
            }
            draft.picks[question.questionID] = pick
        }
    }

    func setOther(_ text: String, for questionID: String) {
        drafts.update(askID) { $0.picks[questionID, default: AskQuestionPick()].other = text }
    }

    func next(of count: Int) {
        page = min(page + 1, max(count - 1, 0))
    }

    func previous() {
        page = max(page - 1, 0)
    }

    // MARK: - Checks, review, note

    func setCheck(_ state: OwnerAskAnswer.CheckState?, for itemID: String) {
        drafts.update(askID) { $0.checks[itemID] = state }
    }

    func setCheckNote(_ note: String, for itemID: String) {
        drafts.update(askID) { $0.checkNotes[itemID] = note }
    }

    func setNote(_ note: String) {
        drafts.update(askID) { $0.note = note }
    }

    /// A comment on `selection` of the shown snapshot (UTF-16 units); nil
    /// for an empty selection.
    @discardableResult
    func addComment(on selection: NSRange, in document: PlainTextDocument, body: String) -> UUID? {
        guard let anchor = CommentAnchorBuilder.anchor(selection: selection, in: document) else { return nil }
        let comment = AskCommentDraft(anchor: anchor, body: body)
        drafts.update(askID) { $0.comments.append(comment) }
        return comment.id
    }

    func setCommentBody(_ body: String, for id: UUID) {
        drafts.update(askID) { draft in
            guard let index = draft.comments.firstIndex(where: { $0.id == id }) else { return }
            draft.comments[index].body = body
        }
    }

    func removeComment(_ id: UUID) {
        drafts.update(askID) { $0.comments.removeAll { $0.id == id } }
    }

    // MARK: - Sending

    /// Sends the draft's answer.
    func send(_ ask: OwnerAsk) async {
        sendError = nil
        do {
            try await answerer.send(ask)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    /// Approve or Request changes: sets the verdict and sends.
    func review(_ verdict: OwnerAskAnswer.Verdict, _ ask: OwnerAsk) async {
        drafts.update(askID) { $0.verdict = verdict }
        await send(ask)
    }

    /// Dismiss on a refused answer: the draft stays.
    func dismiss(rowID: String, snapshot: WorkbenchReplicaSnapshot) {
        guard let row = snapshot.pending.first(where: { $0.id == rowID }) else { return }
        do {
            try answerer.dismiss(row)
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// After `ask_not_open`, moves to the newer open round when there is one
    /// and keeps the old draft's free text in its note. Returns whether it
    /// moved.
    @discardableResult
    func followSuccessor(snapshot: WorkbenchReplicaSnapshot, now: Date) -> Bool {
        guard let form = form(snapshot: snapshot, now: now),
              case let .notOpen(_, rowID, successor?) = form.status,
              let old = snapshot.asks.first(where: { $0.id == askID }) else { return false }
        let carried = draft.freeText(for: old)
        if !carried.isEmpty {
            drafts.update(successor) { draft in
                draft.note = draft.note.isEmpty ? carried : draft.note + "\n\n" + carried
            }
        }
        drafts.discard(askID)
        dismiss(rowID: rowID, snapshot: snapshot)
        askID = successor
        page = 0
        carriedNotice = carried.isEmpty ? nil : AskText.carriedNotice
        return true
    }
}
