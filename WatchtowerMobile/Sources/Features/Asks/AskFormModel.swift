import Foundation
import WatchtowerKit
import WatchtowerSync

/// One ask's form on the phone (spec §13 B4): a question page, the review
/// snapshot with its comments and verdict, the check items, the note, the
/// state of the answer on its way, or a closed ask's stored answer
/// (read-only). Pure: built from the replica, the ask's draft and what the
/// answerer saw.
struct AskFormModel {
    /// One page of a question ask: one question.
    struct QuestionPage: Equatable {
        struct Option: Equatable, Identifiable {
            let label: String
            let description: String
            let recommended: Bool
            let isPicked: Bool

            var id: String { label }
        }

        let questionID: String
        let index: Int
        let count: Int
        let question: String
        let multi: Bool
        let options: [Option]
        let other: String
        var isLast: Bool { index == count - 1 }
    }

    struct Comment: Equatable, Identifiable {
        let id: UUID
        let quote: String
        let body: String
    }

    struct Review: Equatable {
        let docPath: String
        /// The snapshot as plain text; nil when the phone has none.
        let document: PlainTextDocument?
        /// "Showing the first 256 KB of N" when the hub cut the snapshot.
        let clippedNotice: String?
        let comments: [Comment]
        let verdict: OwnerAskAnswer.Verdict?
        /// "Select text to comment · 1 comment".
        let commentsLine: String
    }

    /// One of a check step's three buttons (design pass A5): the `.fill`
    /// symbol in its tone while marked, the outline in secondary otherwise.
    /// Green for OK, red for Broken, secondary for Skipped; never orange.
    struct CheckChoice: Equatable, Identifiable {
        let state: OwnerAskAnswer.CheckState
        /// "OK", "Broken", "Skipped": the button's VoiceOver label.
        let label: String
        let symbol: String
        let tone: PhoneTone
        let isSelected: Bool

        var id: String { state.rawValue }
    }

    struct CheckRow: Equatable, Identifiable {
        let id: String
        let text: String
        let hint: String
        let state: OwnerAskAnswer.CheckState?
        let note: String
        /// Broken without a note: the Mac would refuse it.
        let needsNote: Bool
        /// OK, Broken, Skipped.
        let choices: [CheckChoice]
    }

    /// One part of a closed ask's stored answer: what was asked, over what
    /// was answered (design pass A6).
    struct ClosedLine: Equatable {
        let label: String
        let value: String
    }

    /// The answer on its way, refused, or applied.
    enum Status: Equatable {
        case none
        case sending(String)
        case failed(String, rowID: String)
        /// `ask_not_open`; `successor` is the newer open round, if any.
        case notOpen(String, rowID: String, successor: Int64?)
        case applied(String)
    }

    let askID: Int64
    /// The kind's icon and word ("Question"), drawn in `headerTone`.
    let kindIcon: String
    let kindName: String
    /// "#109".
    let idText: String
    /// "1 of 2" on a question ask with more than one question; nil otherwise.
    let pageText: String?
    let headerTone: PhoneTone
    let title: String
    /// "From <session> · #415".
    let subline: String
    let summary: String
    let changes: String
    let focus: [String]
    /// Set when the payload did not fit (`payload_clipped`): the form is
    /// only this.
    let openOnMac: String?
    let question: QuestionPage?
    let review: Review?
    let checks: [CheckRow]
    let note: String
    /// Why Send is off when it is the note's length.
    let noteHint: String?
    /// A closed ask: its status and its stored answer, read-only.
    let closedStatus: String?
    let closedLines: [ClosedLine]
    let status: Status
    let isEditable: Bool
    let canSend: Bool
    /// A review: Approve and Request changes (which set the verdict, then
    /// send) would send.
    let canSendVerdict: Bool

    init?(
        askID: Int64,
        snapshot: WorkbenchReplicaSnapshot,
        draft: AskDraft,
        page: Int,
        now: Date,
        applied: AppliedAnswer?,
        isSending: Bool,
        render: (String) -> PlainTextDocument = PlainTextRendering.render
    ) {
        guard let ask = snapshot.asks.first(where: { $0.id == askID }) else { return nil }
        self.askID = askID
        kindIcon = AskKindStyle.icon(ask.kind)
        kindName = AskKindStyle.name(ask.kind)
        idText = "#\(ask.id)"
        title = ask.title
        summary = ask.summary
        changes = ask.changes
        subline = Self.subline(ask, snapshot: snapshot)
        let open = ask.status == .open
        headerTone = open ? .waitingForYou : .secondary
        status = Self.status(ask, snapshot: snapshot, now: now, applied: applied)
        let payload = ask.payload
        let clipped = ask.payloadClipped == true || payload == nil
        openOnMac = open && clipped ? AskText.openOnMac : nil
        focus = (payload?.focus ?? []).map(\.text)
        isEditable = open && !clipped && !isSending && applied == nil && !Self.isPending(status)
        canSend = isEditable && draft.isAnswerable(for: ask) && !Self.isNotOpen(status)
        var withVerdict = draft
        withVerdict.verdict = .approved
        canSendVerdict = ask.kind == .review && isEditable && withVerdict.isAnswerable(for: ask) && !Self.isNotOpen(status)

        let questions = open && !clipped ? payload?.questions ?? [] : []
        let shown = questions.isEmpty ? 0 : min(max(page, 0), questions.count - 1)
        question = questions.isEmpty ? nil : Self.page(questions[shown], index: shown, count: questions.count, draft: draft)
        pageText = questions.count > 1 ? "\(shown + 1) of \(questions.count)" : nil
        review = open && !clipped && ask.kind == .review ? Self.review(ask, draft: draft, render: render) : nil
        checks = open && !clipped ? (payload?.checklist ?? []).map { Self.checkRow($0, draft: draft) } : []
        note = draft.note
        noteHint = AskDraft.trimmed(draft.note).unicodeScalars.count > AskDraft.noteLimit ? AskText.noteTooLong : nil
        closedStatus = open ? nil : AskText.status(ask)
        closedLines = open ? [] : Self.closedLines(ask)
    }

    var footer: String { AskText.footer }

    var toneUses: [ToneUse] {
        [ToneUse(element: "ask \(askID) form header", tone: headerTone, role: .ask)]
            + checks.flatMap { row in
                row.choices.map { ToneUse(element: "ask \(askID) step \(row.id) \($0.label)", tone: $0.tone, role: .status) }
            }
    }
}
