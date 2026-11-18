import ChatUI
import ChatWire
import Foundation
import WatchtowerInterface

/// The phone Inbox's approval card drawn by `ChatUI`'s shared card (mobile Inbox spec §12, board #2018): what the card
/// reads off a Needs approval entry (`ChatAgentAction(inboxCard:)`) and the decision row's state from the entry's press
/// (`InboxApprovalState.make`). The copy lives here and in `InboxPhoneText`; `InboxApprovalStateTests` pins every state.
enum InboxApprovalState {
    /// The decision row's state (§12.4, §12.5):
    /// - without `permissions` Approve becomes "Approve on the Mac" with Reject live, Retry "Retry on the Mac" and
    ///   Dismiss "Dismiss on the Mac"; a recipe draft is "Open Draft — on your Mac" whatever the grants;
    /// - a press on its way turns the row off with its line ("Approving…"), or "Waiting to send" while the hub is away;
    /// - a refusal shows the tower's sentence in red with the row live again; Not delivered shows its named Retry alone;
    /// - Didn't confirm turns the row off until Refresh.
    static func make(
        card: InboxCard, rowState: InboxRowState?, grants: Grants, hubAway: Bool, hubName: String, now: Date, host: TowerHost = .mac
    ) -> ChatApprovalState {
        let model = InboxApprovalModel(card: card, platform: .phone, grants: grants, now: now)
        let action = ChatAgentAction(inboxCard: card)
        let settledNote: String? = switch AgentActionCard.settledOffer(for: action) {
        case .retry where !grants.permissions: ChatText.retryElsewhere(host)
        case .dismiss where !grants.permissions: ChatText.dismissElsewhere(host)
        default: nil
        }
        switch rowState {
        case let .busy(request)?:
            let line = hubAway ? InboxPhoneText.waitingToSendLine(hub: hubName) : InboxPhoneText.busyLine(for: request)
            return ChatApprovalState(showsButtons: true, canAnswer: false, line: line, inFlight: !hubAway,
                                     approveNote: model.approveNote, settledNote: settledNote)
        case let .refused(sentence, .outbox)?:
            return ChatApprovalState(showsButtons: true, canAnswer: false, line: nil, approveNote: model.approveNote,
                                     settledNote: settledNote,
                                     undelivered: .init(line: sentence, retryTitle: rowState?.retryTitle ?? InboxText.retry))
        case let .refused(sentence, .resend)?:
            return ChatApprovalState(showsButtons: true, canAnswer: true, line: model.editNote, gestureError: sentence,
                                     approveNote: model.approveNote, settledNote: settledNote)
        case .unknown?:
            return ChatApprovalState(showsButtons: true, canAnswer: false, line: InboxText.didntConfirmPhone,
                                     approveNote: model.approveNote, settledNote: settledNote)
        case nil:
            return ChatApprovalState(showsButtons: true, canAnswer: true, line: model.editNote,
                                     approveNote: model.approveNote, settledNote: settledNote)
        }
    }

    /// The card's title: the feed's own for a recipe draft (`save_automation`, as the Mac's card names it), else the
    /// shared catalog's (nil).
    static func title(_ card: InboxCard) -> String? {
        guard let approval = card.approval, approval.tool == "save_automation", !approval.title.isEmpty else { return nil }
        return approval.title
    }

    /// The card's body in place of the per-tool one: the feed's summary, quoted, for a recipe draft and for an entry
    /// from an older hub, which sends no `args_display`; nil keeps the shared body.
    static func summary(_ card: InboxCard) -> String? {
        guard let approval = card.approval else { return nil }
        guard approval.tool == "save_automation" || approval.argsDisplay == nil else { return nil }
        return approval.summary.isEmpty ? nil : "“\(approval.summary)”"
    }
}

extension ChatAgentAction {
    /// A Needs approval entry (`a<id>`) as the shared card reads it: the feed's display args (never hashed) and the
    /// digest Approve pins (`args_sha256`, AGENT-07). An entry from an older hub has no `args_display`; its body is
    /// the summary (`InboxApprovalState.summary`).
    init(inboxCard card: InboxCard) {
        let approval = card.approval
        self.init(
            id: Int64(card.id.dropFirst()) ?? 0,
            tool: approval?.tool ?? "",
            external: approval?.external ?? false,
            argsJSON: approval?.argsDisplay ?? "",
            argsStored: false,
            argsSHA256: approval?.argsSHA256 ?? "",
            argsComplete: approval?.argsComplete ?? false,
            reason: approval?.reason ?? "",
            status: approval?.status ?? "pending",
            error: approval?.error ?? ""
        )
    }
}
