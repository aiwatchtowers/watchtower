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
        /// The snapshot's lines as the page draws them (#1787); empty
        /// without a snapshot.
        let paragraphs: [ReviewParagraph]
        /// "Showing the first 256 KB of N — the rest is only on the Mac"
        /// when the hub cut the snapshot.
        let clippedNotice: String?
        /// The line where a cut snapshot stops; nil when it is whole.
        let clippedEnd: String?
        let comments: [Comment]
        /// Paragraph id → the comments drawn under it, in draft order.
        let commentsByParagraph: [Int: [Comment]]
        /// Comments with no paragraph to sit under; drawn after the document.
        let unplacedComments: [Comment]
        let verdict: OwnerAskAnswer.Verdict?
        /// "Press and hold a paragraph to comment · 1 comment".
        let commentsLine: String
    }

    /// One of a check step's three buttons (design pass A5): the `.fill`
    /// symbol in its tone while marked, the outline in secondary otherwise.
    /// Green for OK, red for Broken, secondary for Skipped; never orange.
    struct CheckChoice: Equatable, Identifiable {
        let state: OwnerAskAnswer.CheckState
        /// "Works", "Doesn't work", "Didn't check": the button's word (the Mac's).
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

    /// Where the ask came from, as links (#1786): the session's Workchat and
    /// the board target, each only when the replica has it, so a link never
    /// opens "not found".
    struct SourceLink: Equatable, Identifiable {
        enum Destination: Hashable {
            case session(Int64)
            case target(Int64)
        }

        let destination: Destination
        /// "Open session", "Task #415".
        let title: String
        let icon: String

        var id: Destination { destination }
    }

    /// The agent's last message before the ask, from the session's chat
    /// record when the phone already has one (#1786); never requested here.
    struct AgentContext: Equatable {
        let label: String
        /// Ends with "…" when the hub clipped it.
        let text: String
        /// Long enough to fold behind Show more.
        let isLong: Bool
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
    /// "From <workbench> · <session>"; ends with "· #415" only when the
    /// target is not on the phone (no link then, the number stays).
    let subline: String
    /// Open session, Task #415; empty when neither is on the phone.
    let sourceLinks: [SourceLink]
    /// nil unless the session's chat is already on the phone with an agent
    /// message at or before the ask.
    let agentContext: AgentContext?
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
    /// Request changes: a verdict would send and the owner said what to
    /// change, in a note or a comment with text (#1787; the Mac takes an
    /// empty one, the phone does not send it by one stray tap).
    let canRequestChanges: Bool
    /// Why Request changes is off when that is the only reason.
    let requestChangesHint: String?
    /// Under the check steps: what an unmarked step sends, and while none is
    /// marked, that Send needs one.
    let checkFooter: String
    /// Close without answering is offered (#2114): an open ask of a kind the phone knows, too-large ones included
    /// (a dismissal needs no payload).
    let showsDismiss: Bool
    /// …and would send now: no answer on its way or applied, not refused as no longer open, the note within bound.
    let canDismiss: Bool

    init?(
        askID: Int64,
        snapshot: WorkbenchReplicaSnapshot,
        draft: AskDraft,
        page: Int,
        now: Date,
        applied: AppliedAnswer?,
        isSending: Bool,
        chat: SessionChat? = nil,
        chatAsOf: Date? = nil,
        openedFromSessionID: Int64? = nil,
        render: (String) -> PlainTextDocument = PlainTextRendering.render,
        paragraphs: (PlainTextDocument) -> [ReviewParagraph] = ReviewParagraph.split
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
        sourceLinks = Self.sourceLinks(ask, snapshot: snapshot, openedFromSessionID: openedFromSessionID)
        agentContext = Self.agentContext(ask, chat: chat, asOf: chatAsOf)
        let open = ask.status == .open
        headerTone = open ? .waitingForYou : .secondary
        status = Self.status(ask, snapshot: snapshot, now: now, applied: applied)
        let payload = ask.payload
        let clipped = ask.payloadClipped == true || payload == nil
        openOnMac = open && clipped ? AskText.openOnMac : nil
        focus = (payload?.focus ?? []).map(\.text)
        isEditable = open && !clipped && !isSending && applied == nil && !Self.isPending(status)
        // A check sends only once a step is marked (#1787): an all-unmarked
        // answer reads to the agent as nothing failed.
        let checklist = payload?.checklist ?? []
        let marked = checklist.isEmpty || checklist.contains { draft.checks[$0.id] != nil }
        canSend = isEditable && draft.isAnswerable(for: ask) && !Self.isNotOpen(status) && marked
        checkFooter = marked ? AskText.unmarkedStep : "\(AskText.markOneStep) \(AskText.unmarkedStep)"
        var withVerdict = draft
        withVerdict.verdict = .approved
        canSendVerdict = ask.kind == .review && isEditable && withVerdict.isAnswerable(for: ask) && !Self.isNotOpen(status)
        let saidSomething = !AskDraft.trimmed(draft.note).isEmpty || draft.comments.contains { !AskDraft.trimmed($0.body).isEmpty }
        canRequestChanges = canSendVerdict && saidSomething
        showsDismiss = AskDraft.isDismissable(ask)
        canDismiss = showsDismiss && !isSending && applied == nil && !Self.isPending(status) && !Self.isNotOpen(status)
            && draft.dismissal() != nil
        requestChangesHint = canSendVerdict && !saidSomething ? AskText.requestChangesNeedsWords : nil

        let questions = open && !clipped ? payload?.questions ?? [] : []
        let shown = questions.isEmpty ? 0 : min(max(page, 0), questions.count - 1)
        question = questions.isEmpty ? nil : Self.page(questions[shown], index: shown, count: questions.count, draft: draft)
        pageText = questions.count > 1 ? "\(shown + 1) of \(questions.count)" : nil
        review = open && !clipped && ask.kind == .review ? Self.review(ask, draft: draft, render: render, split: paragraphs) : nil
        checks = open && !clipped ? (payload?.checklist ?? []).map { Self.checkRow($0, draft: draft) } : []
        note = draft.note
        noteHint = AskDraft.trimmed(draft.note).unicodeScalars.count > AskDraft.noteLimit ? AskText.noteTooLong : nil
        closedStatus = open ? nil : AskText.status(ask)
        closedLines = open ? [] : Self.closedLines(ask)
    }

    var footer: String { AskText.footer }

    /// Close without answering's confirmation line; names the note only when one goes with it.
    var dismissConfirmMessage: String {
        AskText.dismissConfirmMessage(hasNote: !AskDraft.trimmed(note).isEmpty)
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "ask \(askID) form header", tone: headerTone, role: .ask)]
            + checks.flatMap { row in
                row.choices.map { ToneUse(element: "ask \(askID) step \(row.id) \($0.label)", tone: $0.tone, role: .status) }
            }
    }
}
