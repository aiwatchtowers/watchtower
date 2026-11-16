import ChatWire
import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// One action of a chat turn (mockup 2c): a pending one waits for the owner — orange, the one "waiting for you"
/// use — with Approve and Reject, which send `chat_action_answer` with the hash of exactly the args shown; without
/// the `permissions` grant the card says where to approve instead. A stale hash comes back `changed`: "The action
/// changed — look again". A settled action shows what became of it.
struct ChatApprovalCardModel: Equatable, Identifiable {
    static let approve = "Approve"
    static let reject = "Reject"
    static let changedLine = "The action changed — look again"
    static let sendingLine = "Sending your answer…"

    let action: ChatFeed.Action
    /// Approve and Reject are live: the action is pending, the phone may answer and the hub answers now.
    let canAnswer: Bool
    let showsButtons: Bool
    /// The hint, the answer on its way, the refusal, or what became of the action.
    let line: String?
    let isWaiting: Bool

    var id: Int64 { action.id }
    var title: String { action.title.isEmpty ? action.tool : action.title }

    init(action: ChatFeed.Action, permissions: Bool, online: Bool, inFlight: Bool, failure: ChatActionFailure?, host: TowerHost) {
        self.action = action
        isWaiting = action.status == "pending"
        showsButtons = isWaiting && permissions
        canAnswer = showsButtons && online && !inFlight
        if isWaiting {
            if !permissions {
                line = ChatText.approveElsewhere(host)
            } else if let failure {
                line = failure.reason == .changed ? Self.changedLine : (failure.message.isEmpty ? ChatSendCoordinator.couldNotSend : failure.message)
            } else {
                line = inFlight ? Self.sendingLine : nil
            }
        } else {
            line = Self.outcome(action)
        }
    }

    static func outcome(_ action: ChatFeed.Action) -> String {
        switch action.status {
        case "approved", "executing": "Approved — running"
        case "applied": "Done"
        case "rejected": "Rejected"
        case "failed": action.reason.map { "Failed: \($0)" } ?? "Failed"
        default: action.status.capitalized
        }
    }

    /// The card's colour: orange only while it waits for the owner.
    var toneUse: ToneUse {
        ToneUse(element: "chat approval card", tone: isWaiting ? PhoneTone.waitingForYou : .secondary, role: isWaiting ? .waiting : .status)
    }
}

/// Mockup 2c's card.
struct ChatApprovalCard: View {
    let model: ChatApprovalCardModel
    let answer: (ChatActionDecision) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(model.title).font(TypeScale.rowEmphasis)
            Text(model.action.tool).font(TypeScale.meta).foregroundStyle(.secondary)
            if !model.action.argsDisplay.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(model.action.argsDisplay).font(TypeScale.code).textSelection(.enabled)
                }
                .padding(.top, Spacing.tight)
            }
            if model.showsButtons {
                HStack(spacing: Spacing.regular) {
                    Button(ChatApprovalCardModel.approve) { answer(.approve) }
                        .buttonStyle(ChatCardButtonStyle(fill: model.toneUse.tone.color, label: .black))
                    Button(ChatApprovalCardModel.reject) { answer(.reject) }
                        .buttonStyle(ChatCardButtonStyle(fill: Fill.card, label: .primary))
                }
                .disabled(!model.canAnswer)
                .padding(.top, Spacing.small)
            }
            if let line = model.line {
                Text(line).font(TypeScale.meta).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.card, in: shape)
        .overlay(shape.strokeBorder(model.isWaiting ? model.toneUse.tone.color : Stroke.hairlineColor, lineWidth: Stroke.hairline * 2))
    }
}

/// A small card button (mockups 2c, 2d, 3b): `fill` behind `label`.
struct ChatCardButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.rowEmphasis)
            .foregroundStyle(label)
            .padding(.horizontal, Spacing.medium)
            .frame(minHeight: PhoneMetrics.minTouch - Spacing.regular)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .opacity(configuration.isPressed ? PhoneOpacity.pressed : 1)
    }
}
