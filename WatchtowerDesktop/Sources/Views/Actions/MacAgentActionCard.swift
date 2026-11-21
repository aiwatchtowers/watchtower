import ChatUI
import ChatWire
import DesignKit
import SwiftUI
import WatchtowerCore

/// The Mac's agent-action card on the Inbox, the target chat and the automation editor: a thin adapter, with no layout
/// of its own, from a loaded `AgentAction` row and the host's closures to ChatUI's `AgentActionCard` — the one card the
/// chat and the iPhone draw too (ask #1409). It keeps the parameters the Mac card always took, and adds the Mac-only
/// pieces as services: the `save_automation` body, the Inbox target-button row, Reconnect Slack and in-app Open.
struct MacAgentActionCard: View {
    let action: AgentAction
    let inFlight: Bool
    let onApprove: () -> Void
    let onReject: () -> Void
    let onRetry: () -> Void
    /// Why this card's last Approve/Reject/Retry failed (`AgentActionFeed.rowErrors`). On a still-`pending` row whose
    /// APPROVE failed (e.g. SQLITE_BUSY, the row never moved) Approve becomes Retry, re-running the same approve; a
    /// failed Reject keeps its labels — Reject is its retry.
    var gestureError: AgentActionFeed.RowError?
    /// Follows an applied action to what it produced. Nil hides the in-app "Open" button; a web destination (a created
    /// Jira issue) still links, since opening a browser needs no navigation.
    var onOpen: ((AgentActionDestination) -> Void)?
    /// Approve with the owner's card edits (`actions approve --patch`), for a tool whose card is editable. Nil = the
    /// card offers no edits and Approve runs `onApprove`.
    var onApproveEdited: ((String) -> Void)?
    /// Re-consents a Slack account whose token lacks the send grant and returns why it failed, nil on success. Nil
    /// hides the button.
    var onReconnectSlack: ((Int64) async -> SlackReconnectOutcome)?
    /// Cancel on Reconnect Slack's waiting line, given the card's account (`AppState.cancelCardSlackSignIn`). Nil
    /// draws no line: the button keeps its spinner.
    var onCancelReconnectSlack: ((Int64) -> Void)?
    /// Where the proposal came from, above the card — "⚙ <automation> · run #<n>". Nil shows nothing.
    var contextLabel: String?
    /// Opens what `contextLabel` names (the automation's card, run open). Nil renders the label as plain text.
    var onOpenContext: (() -> Void)?
    /// The editor chat's newest draft text (the Draft panel's); a pending `save_automation` card whose text differs
    /// warns. nil elsewhere.
    var latestDraftText: String?
    /// The editor chat's cached dry runs, recipe text → the sessions each starts; the save card shows the ones of its
    /// own text. Unused where `latestDraftText` is nil.
    var draftSessions: [String: AutomationDryRunSessions] = [:]
    /// Dismiss on a session call whose outcome is unknown (`ConnectorCallProposal.awaitsDismissal`). Nil hides it.
    var onDismiss: (() -> Void)?
    /// A session-applied call (`claude_ai_connector_call`): whether the live chat session that proposed it still waits
    /// on it. False shows "Chat session ended" and offers no Approve.
    var sessionHoldsCall = false
    /// The Inbox target button's state of this `create_target` proposal; nil elsewhere. When it is `.stuck` the card
    /// draws the shared "Didn't finish" line with **Try again** in place of its Approve/Retry row.
    var targetButtonState: ArtifactTargetButtonState?
    /// False on an older proposal of an Inbox target button whose newest row is another one: no Try again.
    var offersRetry = true

    var body: some View {
        ChatUI.AgentActionCard(action: action, services: services, contextLabel: contextLabel,
                               onOpenContext: onOpenContext, offersRetry: offersRetry)
            .environment(\.chatUIStyle, DesignKitChatStyle())
            .environment(\.chatHostText, .mac)
    }

    private var services: ChatApprovalServices {
        let save = Self.saveModel(action)
        let approve = onApprove
        let approveEdited = onApproveEdited
        let reject = onReject
        let retry = onRetry
        let dismiss = onDismiss
        let holds = sessionHoldsCall
        let state = Self.state(inFlight: inFlight, gestureError: gestureError)
        let row = Self.targetRow(targetButtonState, status: action.status)
        let busy = inFlight
        return ChatApprovalServices(
            decide: { _, answer in
                switch answer {
                case .approve(nil): approve()
                case .approve(let patch?): approveEdited?(patch)
                case .reject: reject()
                }
            },
            state: { _ in state },
            approveEdited: onApproveEdited != nil,
            retry: { _ in retry() },
            dismiss: dismiss.map { dismiss in { _ in dismiss() } },
            reconnectSlack: onReconnectSlack,
            reconnectSlackWaiting: cardSignInWait.map { wait in { wait($0).view } },
            openDestination: onOpen,
            sessionHoldsCall: { _ in holds },
            title: { _ in save?.title },
            details: { action in
                Self.details(save, action: action, latestDraftText: latestDraftText, draftSessions: draftSessions)
            },
            decisionOverride: { _ in Self.targetRowView(row, inFlight: busy, onTryAgain: retry) }
        )
    }

    // MARK: - The Mac's pieces

    /// Reconnect Slack's waiting line while the browser sign-in runs: its texts and what its Cancel does.
    struct SlackSignInWait {
        let copy: SignInWaitCopy
        let cancel: () -> Void

        var view: AnyView {
            AnyView(SignInWaitLine(line: copy.line, hint: copy.hint, cancelTitle: copy.cancelTitle, onCancel: cancel))
        }
    }

    /// The waiting line of the card for account `accountID`: Cancel ends that account's sign-in only.
    static func slackSignInWait(accountID: Int64, cancel: @escaping (Int64) -> Void) -> SlackSignInWait {
        SlackSignInWait(copy: .slack) { cancel(accountID) }
    }

    /// This card's waiting line per account; nil without a Cancel to offer.
    var cardSignInWait: ((Int64) -> SlackSignInWait)? {
        onCancelReconnectSlack.map { cancel in { Self.slackSignInWait(accountID: $0, cancel: cancel) } }
    }

    /// The row's decision state as the shared card reads it: the CLI call in flight and why the last one failed.
    static func state(inFlight: Bool, gestureError: AgentActionFeed.RowError?) -> ChatApprovalState {
        ChatApprovalState(
            showsButtons: true, canAnswer: true, line: nil, inFlight: inFlight, gestureError: gestureError?.message,
            approveFailed: gestureError?.isApprove == true,
            // An applied create_track's failed `tracks start` stays on its card.
            gestureErrorOutlivesRow: gestureError?.verb == AgentActionFeed.startVerb
        )
    }

    /// One args decode per render for a `save_automation` card; nil for every other tool.
    static func saveModel(_ action: AgentAction) -> SaveAutomationCardModel? {
        action.tool == SaveAutomationCardModel.tool ? SaveAutomationCardModel(action: action) : nil
    }

    static func details(
        _ save: SaveAutomationCardModel?,
        action: AgentAction,
        latestDraftText: String?,
        draftSessions: [String: AutomationDryRunSessions]
    ) -> AnyView? {
        guard let save else { return nil }
        return AnyView(SaveAutomationCardDetails(
            model: save, actionID: action.id,
            differsFromDraft: action.isPending && save.differsFromDraft(latestDraftText),
            sessions: save.draftSessions(latestDraftText: latestDraftText, isPending: action.isPending,
                                         dryRunSessions: draftSessions)
        ))
    }

    /// What an Inbox target button's proposal draws in place of the decision row: an approved or executing row the
    /// button calls stuck, or whose Try again failed without moving it, offers Try again on the same row; one in
    /// flight shows progress only (no Retry while our own or a recent apply may still land). Every other row keeps
    /// its row.
    enum TargetRow: Equatable {
        case stuck, inFlight, decision
    }

    static func targetRow(_ state: ArtifactTargetButtonState?, status: String) -> TargetRow {
        switch state {
        case .stuck?:
            return .stuck
        case .failed?:
            return status == "failed" ? .decision : .stuck
        case .creating?:
            return .inFlight
        default:
            return .decision
        }
    }

    private static func targetRowView(_ row: TargetRow, inFlight: Bool, onTryAgain: @escaping () -> Void) -> AnyView? {
        switch row {
        case .stuck:
            AnyView(ArtifactTargetStuckLine(onTryAgain: onTryAgain)
                .controlSize(.small)
                .disabled(inFlight)
                .accessibilityIdentifier("agentAction.targetStuck"))
        case .inFlight:
            AnyView(ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("agentAction.targetCreating"))
        case .decision:
            nil
        }
    }
}

// MARK: - The shared rules, under the names the Mac's surfaces use

extension MacAgentActionCard {
    static let confluenceEditTool = ConfluenceEdit.tool

    static func title(for action: AgentAction) -> String { ReactionToolCatalog.title(for: action.tool) }
    static func summaryLines(for action: AgentAction) -> [String] { ActionSummaryLines.summaryLines(for: action) }
    static func confluenceEdit(for action: AgentAction) -> ConfluenceEdit? { ConfluenceEdit.proposal(for: action) }
    static func canApprove(_ action: AgentAction) -> Bool { ConfluenceEdit.canApprove(action) }

    static func diffText(before: String, after: String) -> AttributedString {
        ChatUI.AgentActionCard.diffText(before: before, after: after)
    }

    /// The Inbox row's buttons for `action`: the card's own presses. A row approves plainly, so where the card's
    /// Approve needs more — the Slack workspace pick, the automation editor of a `save_automation`, a session call no
    /// session holds — Approve stays on the native card behind **Edit…** / **Open Draft**. `offersRetry` false (a
    /// target button's row with a newer row of the same button): no Retry, as the native card's `offersRetry`.
    static func rowButtons(
        for action: AgentAction, sessionHolds: Bool, offersRetry: Bool = true
    ) -> [InboxRowActionsContent.ActionButton] {
        if action.isExecuting { return [] }
        guard action.isPending else {
            switch ChatUI.AgentActionCard.settledOffer(for: action) {
            case .retry: return offersRetry ? [.retry] : []
            case .dismiss: return [.dismiss]
            case .none: return []
            }
        }
        if action.tool == SaveAutomationCardModel.tool { return [.openDraft, .reject] }
        let approves = switch ChatUI.AgentActionCard.pendingApproval(for: action, editsSlack: true) {
        case .session:
            ConnectorCallProposal.canApprove(action, sessionHolds: sessionHolds)
                && ConnectorCallProposal(action: action) != nil
        case let .slack(slack): slack.canApprove(text: slack.text, pick: nil)
        case .plain: true
        case .none: false
        }
        return (approves ? [.approve] : []) + [.reject, .edit]
    }

    /// The proposal's own words, what an Inbox row shows under its line: the card's summary of the args. The tool's
    /// name, which the row or its card already shows, only when there is nothing else to say.
    static func rowSummary(for action: AgentAction) -> String {
        if action.tool == SaveAutomationCardModel.tool { return SaveAutomationCardModel(action: action).title }
        let detail: [String] = if let connector = ConnectorCallProposal(action: action) {
            [connector.server, connector.toolName]
        } else if action.isSessionApplied {
            [] // unreadable: the card falls back to raw args, the row to the name
        } else if let slack = SlackSendProposal(action: action) {
            [slack.recipientLine, slack.text]
        } else {
            summaryLines(for: action)
        }
        let words = detail.filter { !$0.isEmpty }
        return words.isEmpty ? title(for: action) : words.joined(separator: " · ")
    }
}

// MARK: - The chat's services

extension ChatApprovalServices {
    /// The Mac chat's approval cards on the conversation's `AgentActionFeed`: a part resolves to its loaded row, and
    /// every decision goes through `watchtower actions …` with the owner-confirm (D12), never `chat.sock` — so the
    /// cards stay live while the chat's socket is unreachable.
    @MainActor
    static func mac(
        feed: AgentActionFeed,
        highlighted: ((AgentAction) -> Bool)? = nil,
        reconnectSlack: @escaping (Int64) async -> SlackReconnectOutcome,
        cancelReconnectSlack: @escaping (Int64) -> Void,
        sessionHolds: @escaping (AgentAction) -> Bool
    ) -> ChatApprovalServices {
        ChatApprovalServices(
            resolve: { payload in feed.rows.first { $0.id == payload.id } },
            decide: { action, answer in
                switch answer {
                case .approve(let patch):
                    // The digest of what the card showed (AGENT-07): the stored args of a loaded row, the payload's
                    // digest before it loads. A card without one offers no Approve.
                    guard let digest = action.approveDigest else { return }
                    Task { await feed.approve(action.id, digest: digest, patch: patch) }
                case .reject:
                    Task { await feed.reject(action.id) }
                }
            },
            state: { action in
                MacAgentActionCard.state(inFlight: feed.inFlight.contains(action.id), gestureError: feed.rowErrors[action.id])
            },
            approveEdited: true,
            retry: { action in Task { await feed.retry(action.id) } },
            dismiss: { action in Task { await feed.dismiss(action.id) } },
            approveAll: { turn in Task { await feed.approveAllPending(forTurn: turn) } },
            reconnectSlack: reconnectSlack,
            reconnectSlackWaiting: { MacAgentActionCard.slackSignInWait(accountID: $0, cancel: cancelReconnectSlack).view },
            sessionHoldsCall: sessionHolds,
            title: { MacAgentActionCard.saveModel($0)?.title },
            details: { action in
                MacAgentActionCard.details(MacAgentActionCard.saveModel(action), action: action, latestDraftText: nil,
                                           draftSessions: [:])
            },
            highlighted: highlighted
        )
    }
}
