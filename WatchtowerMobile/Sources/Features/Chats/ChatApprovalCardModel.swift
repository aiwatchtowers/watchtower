import ChatUI
import ChatWire
import Foundation
import WatchtowerKit

/// One action of a chat turn as the phone may answer it (mockup 2c), drawn by `ChatUI`'s approval card: a pending one
/// waits for the owner — orange, the one "waiting for you" use — with Approve and Reject, which send
/// `chat_action_answer` with the hash of exactly the args shown; without the `permissions` grant the card says where to
/// approve instead and has no buttons. A stale hash comes back `changed`: "The action changed — look again". A settled
/// action shows what became of it.
struct ChatApprovalCardModel: Equatable {
    static let changedLine = RelayChatClient.changedLine
    static let sendingLine = RelayChatClient.answeringLine

    let payload: ChatApprovalPayload
    /// Approve and Reject are live: the action is pending, the phone may answer, the hub answers now and no answer is
    /// on its way.
    let canAnswer: Bool
    let showsButtons: Bool
    /// The hint, the answer on its way, the refusal, or what became of the action.
    let line: String?
    let isWaiting: Bool

    init(payload: ChatApprovalPayload, permissions: Bool, online: Bool, inFlight: Bool, failure: ChatActionFailure?, host: TowerHost) {
        self.payload = payload
        isWaiting = payload.status == "pending"
        showsButtons = isWaiting && permissions
        canAnswer = showsButtons && online && !inFlight
        if isWaiting {
            if !permissions {
                line = ChatText.approveElsewhere(host)
            } else if inFlight {
                line = Self.sendingLine
            } else if let failure {
                line = failure.reason == .changed ? Self.changedLine : (failure.message.isEmpty ? ChatSendCoordinator.couldNotSend : failure.message)
            } else {
                line = nil
            }
        } else {
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
        ChatApprovalState(showsButtons: showsButtons, canAnswer: canAnswer, line: isWaiting ? line : nil)
    }

    /// The card's colour: orange only while it waits for the owner.
    var toneUse: ToneUse {
        ToneUse(element: "chat approval card", tone: isWaiting ? PhoneTone.waitingForYou : .secondary, role: isWaiting ? .waiting : .status)
    }
}
