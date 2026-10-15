import Foundation
import WatchtowerKit

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
    static let noteTooLong = "The note is over 4000 characters — shorten it to send"
    static let carriedNotice = "This ask was replaced by a newer round. Your earlier draft is in the note."

    /// "Showing the first 256 KB of 2.1 MB" for a snapshot the hub cut.
    static func clipped(docBytes: Int?) -> String {
        let full = docBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "a longer document"
        return "Showing the first 256 KB of \(full)"
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
        ask.status == .open ? "This ask is no longer open on the Mac" : "This ask is no longer open: \(status(ask))"
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
