import ChatUI
import ChatWire
import Foundation
import WatchtowerKit

/// One action of a chat turn as the phone may answer it (mockup 2c), drawn by `ChatUI`'s approval card: a pending one
/// waits for the owner — orange, the one "waiting for you" use — with Approve and Reject, which send
/// `chat_action_answer` with the hash of exactly the args shown; without the `permissions` grant the card says where to
/// approve instead and has no buttons. A stale hash comes back `changed`: "The action changed — look again". A settled
/// action shows what became of it.
///
/// A failed action offers Retry, and a session call whose outcome is unknown Dismiss, by the card's own rule (mobile
/// Inbox spec §12.9, ask #1553), sent as `chat_action_answer` `retry` / `dismiss`. Without the grant, or from a hub
/// whose heartbeat has no `chat_actions`, the card says where to do it instead. While the hub is away the button is
/// off and nothing queues (ask #1570). A press on its way shows a spinner and "Sending your answer…"; a refusal shows
/// the hub's sentence; `outcome_unknown` shows "Didn't confirm" and the button stays off (never sent again).
struct ChatApprovalCardModel: Equatable {
    static let changedLine = RelayChatClient.changedLine
    static let sendingLine = RelayChatClient.answeringLine

    let payload: ChatApprovalPayload
    /// Approve and Reject (or Retry, Dismiss on a settled action) are live: the phone may answer, the hub answers now
    /// and no answer is on its way.
    let canAnswer: Bool
    let showsButtons: Bool
    /// The hint, the answer on its way, the refusal, or what became of the action.
    let line: String?
    let isWaiting: Bool
    /// What a settled action offers (`AgentActionCard.settledOffer`): Retry, Dismiss, or nothing.
    let settledOffer: AgentActionCard.SettledOffer
    /// "Retry on the Mac" / "Dismiss on the Mac" without the grant or the hub's `chat_actions`.
    let settledNote: String?
    /// A settled press's refusal, in red on the card.
    let refusal: String?
    /// A settled press is on its way.
    let settledInFlight: Bool

    init(
        payload: ChatApprovalPayload, permissions: Bool, online: Bool, inFlight: Bool, failure: ChatActionFailure?,
        host: TowerHost, retryDismiss: Bool = false
    ) {
        self.payload = payload
        isWaiting = payload.status == "pending"
        settledOffer = isWaiting ? .none : AgentActionCard.settledOffer(for: ChatAgentAction(payload: payload))
        let mayAct = permissions && retryDismiss
        settledNote = switch settledOffer {
        case .retry where !mayAct: ChatText.retryElsewhere(host)
        case .dismiss where !mayAct: ChatText.dismissElsewhere(host)
        default: nil
        }
        let unconfirmed = failure?.reason == .outcomeUnknown
        if isWaiting {
            showsButtons = permissions
            canAnswer = showsButtons && online && !inFlight
            settledInFlight = false
            refusal = nil
            if !permissions {
                line = ChatText.approveElsewhere(host)
            } else if inFlight {
                line = Self.sendingLine
            } else if let failure {
                line = failure.reason == .changed ? Self.changedLine : (failure.message.isEmpty ? ChatSendCoordinator.couldNotSend : failure.message)
            } else {
                line = nil
            }
        } else if settledOffer != .none, settledNote == nil {
            showsButtons = true
            canAnswer = online && !inFlight && !unconfirmed
            settledInFlight = inFlight
            if inFlight {
                line = Self.sendingLine
                refusal = nil
            } else if unconfirmed {
                line = ChatText.didntConfirm(host)
                refusal = nil
            } else {
                line = nil
                refusal = failure.map { $0.reason == .changed ? Self.changedLine : ($0.message.isEmpty ? ChatSendCoordinator.couldNotSend : $0.message) }
            }
        } else {
            showsButtons = false
            canAnswer = false
            settledInFlight = false
            refusal = nil
            line = Self.outcome(payload)
        }
    }

    static func outcome(_ payload: ChatApprovalPayload) -> String {
        switch payload.status {
        case "approved", "executing": "Approved — running"
        case "applied": "Done"
        case "rejected": "Rejected"
        case "failed": payload.reason.map { "Failed: \($0)" } ?? "Failed"
        default: payload.status.capitalized
        }
    }

    /// The decision row as `ChatUI` draws it (`ChatPartActions.approvalState`).
    var state: ChatApprovalState {
        if isWaiting {
            return ChatApprovalState(showsButtons: showsButtons, canAnswer: canAnswer, line: line)
        }
        return ChatApprovalState(
            showsButtons: true, canAnswer: canAnswer, line: settledOffer == .none || settledNote != nil ? nil : line,
            inFlight: settledInFlight,
            gestureError: refusal, gestureErrorOutlivesRow: refusal != nil, settledNote: settledNote
        )
    }

    /// The card's colour: orange only while it waits for the owner.
    var toneUse: ToneUse {
        ToneUse(element: "chat approval card", tone: isWaiting ? PhoneTone.waitingForYou : .secondary, role: isWaiting ? .waiting : .status)
    }
}
