import ChatUI
import ChatWire
import SwiftUI
import WatchtowerDesign
import WatchtowerInterface

/// A Needs approval entry: a proposal (`a…`) is `ChatUI`'s shared approval card in the phone's style, the same card
/// the phone chat draws (mobile Inbox spec §12, asks #1469 and #1409), wired to the Inbox's presses; a due reminder
/// keeps its own card (`InboxReminderCard`).
struct InboxApprovalCard: View {
    let center: InboxCenter
    let card: InboxCardModel
    let grants: Grants
    let now: Date
    var hubAway = false
    var hubName = ""
    var host: TowerHost = .mac
    var timeZone: TimeZone = .current

    /// The card as the tab draws it: the hub away (Waiting to send), its name and kind from the tab's inputs.
    init(center: InboxCenter, card: InboxCardModel, inputs: InboxInputs) {
        self.init(center: center, card: card, grants: inputs.grants, now: inputs.now, hubAway: inputs.macAway != nil,
                  hubName: inputs.hubName, host: inputs.host)
    }

    init(
        center: InboxCenter,
        card: InboxCardModel,
        grants: Grants,
        now: Date,
        hubAway: Bool = false,
        hubName: String = "",
        host: TowerHost = .mac,
        timeZone: TimeZone = .current
    ) {
        self.center = center
        self.card = card
        self.grants = grants
        self.now = now
        self.hubAway = hubAway
        self.hubName = hubName
        self.host = host
        self.timeZone = timeZone
    }

    var body: some View {
        if card.card.cardKind == .reminder {
            InboxReminderCard(center: center, card: card, now: now, timeZone: timeZone)
        } else {
            AgentActionCard(
                action: ChatAgentAction(inboxCard: card.card),
                services: Self.services(center: center, card: card.card, grants: grants, hubAway: hubAway, hubName: hubName,
                                        now: now, host: host),
                contextLabel: card.sourceLine.isEmpty ? nil : card.sourceLine,
                offersRetry: card.card.approval?.superseded != true
            )
            .environment(\.chatUIStyle, PhoneChatStyle())
            .environment(\.chatHostText, .phone(hubName))
        }
    }

    /// The shared card's services on a Needs approval entry (§12.3): Approve (pinned to the digest drawn) and Reject,
    /// Retry and Dismiss as `inbox.act` `approval` presses through the center; a Not delivered press's named Retry
    /// re-sends the same outbox action. Approve, Retry and Dismiss need `permissions`; without it the card shows the
    /// notes (`InboxApprovalState`) and these send nothing. Edit… stays on the Mac (no edits here).
    static func services(
        center: InboxCenter, card: InboxCard, grants: Grants, hubAway: Bool, hubName: String, now: Date, host: TowerHost = .mac
    ) -> ChatApprovalServices {
        let model = InboxApprovalModel(card: card, platform: .phone, grants: grants, now: now)
        let press: (ApprovalVerb) -> Void = { verb in
            Task { await center.press { model.request(verb, requestID: $0) } }
        }
        let targetRow = model.targetRow
        return ChatApprovalServices(
            decide: { _, answer in
                switch answer {
                case .approve(nil): if model.canApprove { press(.approve) }
                case .reject: if model.canReject { press(.reject) }
                // No edits on the phone: an edited approve is never sent as a plain one.
                case .approve(_?): break
                }
            },
            state: { _ in
                InboxApprovalState.make(card: card, rowState: center.rowState(card.id), grants: grants, hubAway: hubAway,
                                        hubName: hubName, now: now, host: host)
            },
            retry: { _ in if InboxApprovalState.mayRetry(card, grants: grants) { press(.retry) } },
            dismiss: { _ in if grants.permissions { press(.dismiss) } },
            sessionHoldsCall: InboxApprovalState.sessionHolds,
            title: { _ in InboxApprovalState.title(card) },
            details: { _ in
                InboxApprovalState.summary(card).map {
                    AnyView(Text($0).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true))
                }
            },
            decisionOverride: { _ in
                InboxTargetRow.view(targetRow, canRetry: grants.permissions, host: host) { press(.retry) }
            },
            resend: { _ in
                if case let .refused(_, retry)? = center.rowState(card.id) {
                    Task { await center.retry(retry) }
                }
            }
        )
    }
}

/// What an Inbox target button's proposal draws in place of the decision row (`InboxApprovalModel.targetRow`, the
/// Mac's `MacAgentActionCard.targetRowView`): stuck offers "Didn't finish" with Try again; creating shows progress;
/// anything else keeps the card's row (nil).
enum InboxTargetRow {
    static func view(
        _ row: InboxApprovalModel.TargetRow, canRetry: Bool, host: TowerHost = .mac, onTryAgain: @escaping () -> Void
    ) -> AnyView? {
        switch row {
        case .decision:
            return nil
        case .inFlight:
            return AnyView(ProgressView().controlSize(.small))
        case .stuck:
            return AnyView(InboxStuckTargetRow(canRetry: canRetry, host: host, onTryAgain: onTryAgain))
        }
    }
}

private struct InboxStuckTargetRow: View {
    let canRetry: Bool
    let host: TowerHost
    let onTryAgain: () -> Void
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Text(InboxText.didntFinish).font(.caption).foregroundStyle(.secondary)
            if canRetry {
                style.approvalButton(InboxText.tryAgain, prominent: true, action: onTryAgain)
            } else {
                Text(ChatText.retryElsewhere(host)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A due reminder in Needs approval: its time, its note, the message it is about, and Done and Snooze 1h through the
/// reminder ref's own presses.
struct InboxReminderCard: View {
    let center: InboxCenter
    let card: InboxCardModel
    let now: Date
    var timeZone: TimeZone = .current
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title).font(TypeScale.rowEmphasis)
            if !card.preview.isEmpty {
                Text(card.preview).font(TypeScale.rowTitle).lineLimit(3)
            }
            if let url = PhoneArtifactLayout.webURL(card.card.link) {
                Button(InboxPhoneText.openInDetail(InboxPhoneText.messageLink)) { openURL(url) }
                    .font(TypeScale.meta)
                    .foregroundStyle(PhoneTone.accent.color)
            }
            if let row = card.refRows.first {
                reminderButtons(row).padding(.top, Spacing.compact)
            }
        }
        .card(.waiting)
    }

    private var title: String {
        guard let at = InboxCardRowModel.date(card.card.stamp) else { return card.title }
        return InboxText.reminderLine(at: at, timeZone: timeZone)
    }

    private func reminderButtons(_ row: InboxRefRowModel) -> some View {
        let actions = InboxRefRowActions(center: center, card: card, now: now, onReply: { _ in }, openURL: { openURL($0) })
        let drawn = actions(ArtifactRef(kind: .reminder, id: row.facts.id))
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            if let error = drawn.error {
                Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
            }
            FlowRow(spacing: Spacing.regular, lineSpacing: Spacing.regular) {
                if center.rowState(row.key)?.isUndelivered == true, let retry = drawn.retry {
                    // Not delivered: its named Retry is the reminder's one action.
                    Button(retry.title, action: retry.action).buttonStyle(PhoneArtifactButtonStyle(primary: true))
                } else {
                    ForEach(Array(row.menu.enumerated()), id: \.offset) { offset, verb in
                        Button(InboxRefVerbs.title(verb, kind: row.facts.kind)) { actions.press(verb, row) }
                            .buttonStyle(PhoneArtifactButtonStyle(primary: offset == 0))
                    }
                }
            }
        }
    }
}
