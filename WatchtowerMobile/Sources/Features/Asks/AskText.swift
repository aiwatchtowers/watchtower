import Foundation
import WatchtowerKit

/// The fixed texts of the ask forms (spec §4.6, §6.2, §9).
enum AskText {
    static let openOnMac = "Open the ask on the tower"
    static let openOnMacReason = "This ask is too large to answer on the phone."
    static let footer = "The answer is typed into the session on the tower"
    static let send = "Send answer"
    static let next = "Next question"
    static let previous = "Previous"
    static let approve = "Approve"
    static let requestChanges = "Request changes"
    static let appliedWithoutDelivery = "Answer saved on the tower"
    static let genericFailure = "Your tower could not take this answer"
    static let noteTooLong = "The note is over 4000 characters — shorten it to send"
    static let openSession = "Open session"
    static let agentContextLabel = "Agent, before asking"
    static let showMore = "Show more"
    static let showLess = "Show less"
    /// The agent's message folds past these (5 lines shown).
    static let agentContextFoldCharacters = 280
    static let agentContextFoldLines = 5
    static let carriedNotice = "This ask was replaced by a newer round. Your earlier draft is in the note."

    static let commentHint = "Press and hold a paragraph to comment"
    static let comment = "Comment"
    static let copy = "Copy"
    static let commentSheetHint = "Select words to comment on just them, or leave it as is to comment on the whole paragraph."
    static let commentNotAdded = "This comment could not be placed on the text. Select other words or none, then Add again."
    static let requestChangesNeedsWords = "Add a comment or a note to request changes"
    static let markOneStep = "Mark at least one step to send."
    static let unmarkedStep = "A step you leave unmarked goes as Didn't check."
    static let brokenNote = "What happened? (required)"
    static let stepNote = "Note"

    /// "Task #415": the link to the ask's board target.
    static func task(_ id: Int64) -> String { "Task #\(id)" }

    /// "Showing the first 256 KB of 2.1 MB — the rest is only on the Mac"
    /// for a snapshot the hub cut (the hub publishes at most 256 KiB).
    static func clipped(docBytes: Int?) -> String {
        let full = docBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "a longer document"
        return "Showing the first 256 KB of \(full) — the rest is only on the tower"
    }

    /// Where a cut snapshot stops: what is missing and where to read it.
    static func clippedEnd(docPath: String) -> String {
        let name = docPath.isEmpty ? "the document" : docPath
        return "The phone has only the first 256 KB of \(name). Open the ask on the tower to read the rest."
    }

    /// "Press and hold a paragraph to comment · 1 comment"; the count alone
    /// when there is no snapshot to comment on.
    static func commentsLine(count: Int, hasDocument: Bool) -> String {
        let noun = count == 1 ? "1 comment" : "\(count) comments"
        return hasDocument ? "\(commentHint) · \(noun)" : noun
    }

    /// The ask's status as the replica has it.
    static func status(_ ask: OwnerAsk) -> String {
        if ask.answer?.dismissed == true { return "Dismissed" }
        return switch ask.status {
        case .answered: "Answered"
        case .delivered: "Answered and delivered"
        case .withdrawn: ask.withdrawnReason == .superseded ? "Replaced by a newer round" : "Withdrawn by the agent"
        case .open: "Open"
        default: ask.status.rawValue.capitalized
        }
    }

    /// An `ask_not_open` echo, with the replica's status.
    static func notOpen(_ ask: OwnerAsk) -> String {
        ask.status == .open ? "This ask is no longer open on the tower" : "This ask is no longer open: \(status(ask))"
    }

    /// A check mark in the Mac drawer's words (`OwnerAskPresentation.checkStates`).
    static func check(_ state: OwnerAskAnswer.CheckState) -> String {
        switch state {
        case .ok: "Works"
        case .broken: "Doesn't work"
        case .skipped: "Didn't check"
        default: state.rawValue.capitalized
        }
    }
}
