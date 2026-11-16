import SwiftUI
import WatchtowerInterface

/// A Needs approval entry as a waiting card (mockup §3): the proposal's title, where it came from (or "Failed: …"),
/// its summary quoted, the hub's refusal when there is one ("This proposal changed on the Mac — look again"), and
/// the Mac's decision row through `InboxApprovalModel` — Approve and Reject, Retry and Dismiss on a failed one,
/// "Approve on the Mac" without the grant, "Open Draft — on your Mac" and "Edit on your Mac" where the Mac's
/// editor is needed. A reminder is the same card with Done and Snooze 1h.
struct InboxApprovalCard: View {
    let center: InboxCenter
    let card: InboxCardModel
    let grants: Grants
    let now: Date
    var timeZone: TimeZone = .current
    @Environment(\.openURL) private var openURL

    private var approval: InboxApprovalModel {
        InboxApprovalModel(card: card.card, platform: .phone, grants: grants, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title).font(TypeScale.rowEmphasis)
            if let failed = approval.failedLine {
                Text(failed).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
            } else if !meta.isEmpty {
                Text(meta).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            if !quote.isEmpty {
                Text(quote).font(TypeScale.rowTitle).lineLimit(3)
            }
            if card.card.cardKind == .reminder, let url = PhoneArtifactLayout.webURL(card.card.link) {
                Button(InboxPhoneText.openInDetail(InboxPhoneText.messageLink)) { openURL(url) }
                    .font(TypeScale.meta)
                    .foregroundStyle(PhoneTone.accent.color)
            }
            if let error = refusal {
                Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color).padding(.top, Spacing.tight)
            }
            buttons.padding(.top, Spacing.compact)
            if let note = approval.editNote {
                Text(note).font(TypeScale.meta).foregroundStyle(.secondary)
            }
        }
        .card(.waiting)
    }

    private var title: String {
        if card.card.cardKind == .reminder, let at = InboxCardRowModel.date(card.card.stamp) {
            return InboxText.reminderLine(at: at, timeZone: timeZone)
        }
        return card.card.approval?.title.isEmpty == false ? card.card.approval?.title ?? card.title : card.title
    }

    private var meta: String { card.card.cardKind == .reminder ? "" : card.sourceLine }

    private var quote: String {
        let text = card.card.cardKind == .reminder ? card.preview : (card.card.approval?.summary ?? card.preview)
        return text.isEmpty || card.card.cardKind == .reminder ? text : "“\(text)”"
    }

    /// The newest press's refusal or unconfirmed line on this card.
    private var refusal: String? {
        switch center.rowState(card.id)?.state {
        case let .refused(sentence)?: sentence
        case .unknown?: InboxText.didntConfirmPhone
        default: nil
        }
    }

    @ViewBuilder private var buttons: some View {
        if card.card.cardKind == .reminder, let row = card.refRows.first {
            reminderButtons(row)
        } else {
            decisionButtons
        }
    }

    @ViewBuilder private var decisionButtons: some View {
        let model = approval
        FlowRow(spacing: Spacing.regular, lineSpacing: Spacing.regular) {
            switch model.targetRow {
            case .inFlight:
                ProgressView().controlSize(.small)
            case .stuck:
                Text(InboxText.didntFinish).font(TypeScale.meta).foregroundStyle(.secondary)
                verb(.retry, InboxText.tryAgain, primary: true, busy: InboxText.approving)
            case .decision:
                let busy = Self.busyVerb(card.card) { center.state($0) }
                if busy == nil, !model.canApprove, let note = model.approveNote {
                    Button(note) {}.buttonStyle(PhoneArtifactButtonStyle(primary: false)).disabled(true).opacity(PhoneOpacity.disabled)
                }
                ForEach(Self.shownVerbs(model, busy: busy), id: \.rawValue) { item in
                    verb(item, Self.title(item), primary: item == .approve || item == .retry, busy: Self.busyTitle(item))
                }
            }
        }
    }

    /// The decision row's verbs (mockup §3): Approve, Retry, Reject, Dismiss as the model offers them; while one is
    /// on its way only that one shows ("Approving…").
    static func shownVerbs(_ model: InboxApprovalModel, busy: ApprovalVerb?) -> [ApprovalVerb] {
        if let busy { return [busy] }
        return [
            model.canApprove ? ApprovalVerb.approve : nil,
            model.canRetry ? .retry : nil,
            model.canReject ? .reject : nil,
            model.canDismiss ? .dismiss : nil
        ].compactMap { $0 }
    }

    /// The approval verb of `card` whose press is on its way, if any.
    static func busyVerb(_ card: InboxCard, state: (String) -> TowerActionState?) -> ApprovalVerb? {
        [ApprovalVerb.approve, .retry, .reject, .dismiss].first { state(InboxPressKey.approval(card, $0)) == .busy }
    }

    static func title(_ verb: ApprovalVerb) -> String {
        switch verb {
        case .approve: InboxText.approve
        case .retry: InboxText.retry
        case .reject: InboxText.reject
        default: InboxText.dismiss
        }
    }

    static func busyTitle(_ verb: ApprovalVerb) -> String? {
        switch verb {
        case .approve, .retry: InboxText.approving
        case .reject: InboxText.rejecting
        default: nil
        }
    }

    private func verb(_ verb: ApprovalVerb, _ title: String, primary: Bool, busy: String?) -> some View {
        let key = InboxPressKey.approval(card.card, verb)
        let isBusy = center.state(key) == .busy
        let request = approval
        return Button {
            Task {
                await center.press(key, on: card.id, hides: verb != .retry, busy: busy) { request.request(verb, requestID: $0) }
            }
        } label: {
            if isBusy {
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.mini)
                    Text(busy ?? title)
                }
            } else {
                Text(title)
            }
        }
        .buttonStyle(PhoneArtifactButtonStyle(primary: primary))
        .disabled(isBusy || center.state(key) == .unknown)
        .opacity(isBusy ? PhoneOpacity.dimmed : 1)
    }

    private func reminderButtons(_ row: InboxRefRowModel) -> some View {
        let actions = InboxRefRowActions(center: center, card: card, now: now, onReply: { _ in }, openURL: { openURL($0) })
        return FlowRow(spacing: Spacing.regular, lineSpacing: Spacing.regular) {
            ForEach(Array(row.menu.enumerated()), id: \.offset) { offset, verb in
                Button(InboxRefVerbs.title(verb, kind: row.facts.kind)) { actions.press(verb, row) }
                    .buttonStyle(PhoneArtifactButtonStyle(primary: offset == 0))
            }
        }
    }
}
