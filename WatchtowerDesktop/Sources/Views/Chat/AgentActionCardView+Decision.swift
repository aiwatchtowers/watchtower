import Foundation
import WatchtowerCore

/// The card's decision rules in one place: its decision row draws from
/// them, and an Inbox row with this proposal as its `ref` offers the same
/// presses (inbox builder B, "Native row actions for a `ref`").
extension AgentActionCardView {
    /// How a pending row offers Approve.
    enum PendingApproval: Equatable {
        /// A session-applied call: Approve while the chat session holds it
        /// and the card can read it (`connectorButtons`).
        case session
        /// A Slack send the owner can edit: Approve & send once a workspace
        /// is chosen and the text is sendable (`SlackSendProposal.canApprove`).
        case slack(SlackSendProposal)
        case plain
        /// No Approve: an unreadable Confluence edit (F7).
        case none
    }

    /// What a row no longer pending offers.
    enum SettledOffer: Equatable {
        case retry
        /// A session call whose outcome is unknown (`ConnectorCallProposal.awaitsDismissal`).
        case dismiss
        case none
    }

    static func pendingApproval(for action: AgentAction, editsSlack: Bool) -> PendingApproval {
        if action.isSessionApplied { return .session }
        if editsSlack, let slack = SlackSendProposal(action: action) { return .slack(slack) }
        return canApprove(action) ? .plain : .none
    }

    static func settledOffer(for action: AgentAction) -> SettledOffer {
        if action.canRetry { return .retry }
        return ConnectorCallProposal.awaitsDismissal(action) ? .dismiss : .none
    }

    /// The Inbox row's buttons for `action`: the card's own presses. A row
    /// approves plainly, so where the card's Approve needs more — the Slack
    /// workspace pick, the automation editor of a `save_automation`, a
    /// session call no session holds — Approve stays on the native card
    /// behind **Edit…** / **Open Draft**.
    static func rowButtons(for action: AgentAction, sessionHolds: Bool) -> [InboxRowActionsContent.ActionButton] {
        if action.isExecuting { return [] }
        guard action.isPending else {
            switch settledOffer(for: action) {
            case .retry: return [.retry]
            case .dismiss: return [.dismiss]
            case .none: return []
            }
        }
        if action.tool == SaveAutomationCardModel.tool { return [.openDraft, .reject] }
        let approves = switch pendingApproval(for: action, editsSlack: true) {
        case .session:
            ConnectorCallProposal.canApprove(action, sessionHolds: sessionHolds)
                && ConnectorCallProposal(action: action) != nil
        case let .slack(slack): slack.canApprove(text: slack.text, pick: nil)
        case .plain: true
        case .none: false
        }
        return (approves ? [.approve] : []) + [.reject, .edit]
    }
}
