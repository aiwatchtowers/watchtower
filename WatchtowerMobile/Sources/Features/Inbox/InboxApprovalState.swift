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
        let approveNote = Self.approveNote(card, model: model, host: host, hubName: hubName)
        let settledNote: String? = switch AgentActionCard.settledOffer(for: action) {
        case .retry where !grants.permissions: ChatText.retryElsewhere(host)
        case .dismiss where !grants.permissions: ChatText.dismissElsewhere(host)
        default: nil
        }
        switch rowState {
        case let .busy(request)?:
            let line = hubAway ? InboxPhoneText.waitingToSendLine(hub: hubName) : InboxPhoneText.busyLine(for: request)
            return ChatApprovalState(showsButtons: true, canAnswer: false, line: line, inFlight: !hubAway,
                                     approveNote: approveNote, settledNote: settledNote)
        case let .refused(sentence, .outbox)?:
            return ChatApprovalState(showsButtons: true, canAnswer: false, line: nil, approveNote: approveNote,
                                     settledNote: settledNote,
                                     undelivered: .init(line: sentence, retryTitle: rowState?.retryTitle ?? InboxText.retry))
        case let .refused(sentence, .resend)?:
            return ChatApprovalState(showsButtons: true, canAnswer: true, line: model.editNote, gestureError: sentence,
                                     approveNote: approveNote, settledNote: settledNote)
        case .unknown?:
            return ChatApprovalState(showsButtons: true, canAnswer: false, line: InboxText.didntConfirmPhone,
                                     approveNote: approveNote, settledNote: settledNote)
        case nil:
            return ChatApprovalState(showsButtons: true, canAnswer: true, line: model.editNote,
                                     approveNote: approveNote, settledNote: settledNote)
        }
    }

    /// Approve's note: "Open Draft — on your Mac" for a recipe draft, else where to approve without the grant,
    /// naming the Mac or the tower (§12.3, `ChatText.approveElsewhere`).
    /// A Slack send still waiting for its workspace (`needs_workspace`, decided by the hub from the whole args, even
    /// when the display args reached the phone clipped) offers no Approve: "Choose a workspace on <hub> before
    /// approving", as the shared card says when it can read the args.
    static func approveNote(_ card: InboxCard, model: InboxApprovalModel, host: TowerHost, hubName: String = "") -> String? {
        if card.approval?.needsWorkspace == true, card.approval?.status == "pending" {
            return ChatHostText.phone(hubName).chooseSlackWorkspace
        }
        guard let note = model.approveNote else { return nil }
        return card.approval?.tool == "save_automation" ? note : ChatText.approveElsewhere(host)
    }

    /// Retry is offered by the card's own rule (`AgentActionCard.settledOffer`) on an entry that is not an older
    /// button proposal, and sent only with the `permissions` grant.
    static func mayRetry(_ card: InboxCard, grants: Grants) -> Bool {
        grants.permissions && card.approval?.superseded != true
            && AgentActionCard.settledOffer(for: ChatAgentAction(inboxCard: card)) == .retry
    }

    /// A claude.ai connector call in Needs approval: a pending (or approved, running) row exists only while its chat
    /// session holds it — the chat's gate fails the row when the session dies — so the Inbox reads it as held:
    /// Approve with the grant, never "Chat session ended" on a live call (#1006 review I1).
    static func sessionHolds(_ action: ChatAgentAction) -> Bool {
        ["pending", "approved", "executing"].contains(action.status)
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
