import Foundation
import WatchtowerKit
import WatchtowerSync

/// The fixed texts of the ask forms (spec §4.6, §6.2, §9).
enum AskText {
    static let openOnMac = "Open the ask on the Mac"
    static let openOnMacReason = "This ask is too large to answer on the phone."
    static let footer = "The answer is typed into the session on the Mac"
    static let send = "Send answer"
    static let next = "Next question"
    static let previous = "Previous"
    static let approve = "Approve"
    static let requestChanges = "Request changes"
    static let appliedWithoutDelivery = "Answer saved on the Mac"
    static let genericFailure = "Your Mac could not take this answer"
    static let carriedNotice = "This ask was replaced by a newer round. Your earlier draft is in the note."

    /// "Showing the first 256 KB of 2.1 MB" for a snapshot the hub cut.
    static func clipped(docBytes: Int?) -> String {
        let full = docBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "a longer document"
        return "Showing the first 256 KB of \(full)"
    }

    /// The ask's status as the replica has it.
    static func status(_ ask: OwnerAsk) -> String {
        switch ask.status {
        case .answered: "Answered"
        case .delivered: "Answered and delivered"
        case .withdrawn: ask.withdrawnReason == .superseded ? "Replaced by a newer round" : "Withdrawn by the agent"
        case .open: "Open"
        default: ask.status.rawValue.capitalized
        }
    }

    /// An `ask_not_open` echo, with the replica's status.
    static func notOpen(_ ask: OwnerAsk) -> String {
        ask.status == .open ? "This ask is no longer open on the Mac" : "This ask is no longer open: \(status(ask))"
    }

    static func kind(_ kind: OwnerAsk.Kind) -> String {
        switch kind {
        case .review: "REVIEW"
        case .check: "CHECK"
        case .question: "QUESTION"
        default: kind.rawValue.uppercased()
        }
    }

    static func check(_ state: OwnerAskAnswer.CheckState) -> String {
        switch state {
        case .ok: "OK"
        case .broken: "Broken"
        case .skipped: "Skipped"
        default: state.rawValue.capitalized
        }
    }
}

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

    struct CheckRow: Equatable, Identifiable {
        let id: String
        let text: String
        let hint: String
        let state: OwnerAskAnswer.CheckState?
        let note: String
        /// Broken without a note: the Mac would refuse it.
        let needsNote: Bool
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
    /// "ASK #109 · QUESTION · 1 OF 2".
    let header: String
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
    /// A closed ask: its status and its stored answer, read-only.
    let closedStatus: String?
    let closedLines: [String]
    let status: Status
    let isEditable: Bool
    let canSend: Bool

    init?(
        askID: Int64,
        snapshot: WorkbenchReplicaSnapshot,
        draft: AskDraft,
        page: Int,
        now: Date,
        applied: AppliedAnswer?,
        isSending: Bool
    ) {
        guard let ask = snapshot.asks.first(where: { $0.id == askID }) else { return nil }
        self.askID = askID
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

        let questions = open && !clipped ? payload?.questions ?? [] : []
        let shown = questions.isEmpty ? 0 : min(max(page, 0), questions.count - 1)
        question = questions.isEmpty ? nil : Self.page(questions[shown], index: shown, count: questions.count, draft: draft)
        var header = "ASK #\(ask.id) · \(AskText.kind(ask.kind))"
        if questions.count > 1 { header += " · \(shown + 1) OF \(questions.count)" }
        self.header = header
        review = open && !clipped && ask.kind == .review ? Self.review(ask, draft: draft) : nil
        checks = open && !clipped ? (payload?.checklist ?? []).map { Self.checkRow($0, draft: draft) } : []
        note = draft.note
        closedStatus = open ? nil : AskText.status(ask)
        closedLines = open ? [] : Self.closedLines(ask)
    }

    var footer: String { AskText.footer }

    var toneUses: [ToneUse] {
        [ToneUse(element: "ask \(askID) form header", tone: headerTone, role: .ask)]
    }

    // MARK: - Parts

    private static func subline(_ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot) -> String {
        var parts = [ask.workbenchName]
        if let session = ask.sessionID.flatMap(snapshot.session) {
            parts.append(session.title)
        }
        if let target = ask.targetID {
            parts.append("#\(target)")
        }
        return "From " + parts.joined(separator: " · ")
    }

    private static func page(_ question: OwnerAskPayload.Question, index: Int, count: Int, draft: AskDraft) -> QuestionPage {
        let pick = draft.picks[question.id] ?? AskQuestionPick()
        return QuestionPage(
            questionID: question.id,
            index: index,
            count: count,
            question: question.question,
            multi: question.multi,
            options: question.options.map { option in
                .init(
                    label: option.label,
                    description: option.description,
                    recommended: option.recommended,
                    isPicked: pick.labels.contains(option.label)
                )
            },
            other: pick.other
        )
    }

    private static func review(_ ask: OwnerAsk, draft: AskDraft) -> Review {
        let count = draft.comments.count
        let noun = count == 1 ? "1 comment" : "\(count) comments"
        return Review(
            docPath: ask.docPath,
            document: ask.docSnapshot.map(PlainTextRendering.render),
            clippedNotice: ask.docClipped == true ? AskText.clipped(docBytes: ask.docBytes) : nil,
            comments: draft.comments.map { Comment(id: $0.id, quote: $0.anchor.quote, body: $0.body) },
            verdict: draft.verdict,
            commentsLine: ask.docSnapshot == nil ? noun : "Select text to comment · \(noun)"
        )
    }

    private static func checkRow(_ item: OwnerAskPayload.CheckItem, draft: AskDraft) -> CheckRow {
        let state = draft.checks[item.id]
        let note = draft.checkNotes[item.id] ?? ""
        return CheckRow(
            id: item.id, text: item.text, hint: item.hint, state: state, note: note,
            needsNote: state == .broken && AskDraft.trimmed(note).isEmpty
        )
    }

    private static func closedLines(_ ask: OwnerAsk) -> [String] {
        guard let answer = ask.answer else { return [] }
        var lines: [String] = []
        if let verdict = answer.verdict {
            lines.append(verdict == .approved ? "Approved" : "Changes requested")
        }
        let questions = Dictionary((ask.payload?.questions ?? []).map { ($0.id, $0.question) }) { first, _ in first }
        for item in answer.answers {
            let picked = (item.labels + (item.other.isEmpty ? [] : ["Other: \(item.other)"])).joined(separator: ", ")
            lines.append("\(questions[item.id] ?? item.id): \(picked)")
        }
        let checks = Dictionary((ask.payload?.checklist ?? []).map { ($0.id, $0.text) }) { first, _ in first }
        for item in answer.checklist {
            let note = item.note.isEmpty ? "" : " — \(item.note)"
            lines.append("\(checks[item.id] ?? item.id): \(AskText.check(item.state))\(note)")
        }
        lines += answer.comments.map { "“\($0.quote)” — \($0.body)" }
        if !answer.note.isEmpty { lines.append("Note: \(answer.note)") }
        return lines
    }

    // MARK: - The answer on its way

    private static func status(
        _ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot, now: Date, applied: AppliedAnswer?
    ) -> Status {
        let entity = AskAnswerer.recordName(ask.id)
        let rows = snapshot.pending.filter { $0.action.kind == .askAnswer && $0.entityRecordName == entity }
        guard let row = rows.last else {
            return applied.map { .applied($0.text) } ?? .none
        }
        switch row.state {
        case .pending:
            let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
            return .sending(online ? BoardWriteText.sending : BoardWriteText.waitingForMac)
        case .failed:
            if row.reason == .askNotOpen {
                return .notOpen(AskText.notOpen(ask), rowID: row.id, successor: successor(of: ask.id, in: snapshot)?.id)
            }
            let message = row.errorMessage.flatMap { $0.isEmpty || $0 == ActionOutbox.noMessageFallback ? nil : $0 }
            return .failed(message ?? AskText.genericFailure, rowID: row.id)
        }
    }

    /// The newest round of a review chain after `askID` (`previous_ask_id`
    /// links), when it is open.
    static func successor(of askID: Int64, in snapshot: WorkbenchReplicaSnapshot) -> OwnerAsk? {
        var seen: Set<Int64> = [askID]
        var newest: OwnerAsk?
        var current = askID
        while let next = snapshot.asks.first(where: { $0.previousAskID == current }), seen.insert(next.id).inserted {
            newest = next
            current = next.id
        }
        return newest?.status == .open ? newest : nil
    }

    private static func isPending(_ status: Status) -> Bool {
        if case .sending = status { return true }
        return false
    }

    private static func isNotOpen(_ status: Status) -> Bool {
        if case .notOpen = status { return true }
        return false
    }
}
