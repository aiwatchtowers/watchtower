import ChatWire
import SwiftUI
import WatchtowerDesign

/// One agent action — a write-tool proposal — as a card, the same on the Mac and the iPhone (ask #1409): the Mac's
/// chat, Inbox, target chat and automation editor, and the phone's chat. Generic over the tool: the argument rendering
/// is the only per-tool code; state comes from the row (Go owns transitions), so the card never guesses what happened.
/// Every effect goes through the injected `ChatApprovalServices`; a capability that is nil hides its control. The look
/// comes from `ChatUIStyle` (the Mac's accent card, the phone's card).
public struct AgentActionCard: View {
    let action: ChatAgentAction
    let services: ChatApprovalServices
    /// Where the proposal came from, above the card ("⚙ <automation> · run #<n>"); nil shows nothing.
    let contextLabel: String?
    /// Opens what `contextLabel` names; nil renders the label as plain text.
    let onOpenContext: (() -> Void)?
    let outlined: Bool
    /// False on an older proposal of an Inbox target button whose newest row is another one: no Retry.
    let offersRetry: Bool

    @Environment(\.chatUIStyle) var style

    /// The pending Slack send's edited text (nil = untouched) and workspace pick.
    @State var slackDraft: String?
    @State var slackPick: Int?
    /// The card's own Slack gestures: an edit that could not be encoded, and the outcome of Reconnect Slack.
    @State var slackMessage: String?
    @State private var reconnecting = false
    /// The connector call's input while the owner edits it; nil = not editing.
    @State var connectorDraft: String?

    public init(
        action: ChatAgentAction,
        services: ChatApprovalServices,
        contextLabel: String? = nil,
        onOpenContext: (() -> Void)? = nil,
        outlined: Bool = false,
        offersRetry: Bool = true
    ) {
        self.action = action
        self.services = services
        self.contextLabel = contextLabel
        self.onOpenContext = onOpenContext
        self.outlined = outlined
        self.offersRetry = offersRetry
    }

    /// After a sign-in that reported no error — which a cancelled one does not either, and a grant Slack still refused
    /// send for neither.
    static let reconnectDoneNote = "Sign-in closed. Press Retry — if sending is still refused, Slack has not "
        + "allowed it for this workspace yet (its app settings or admin must)."

    /// The shared human name (`ActionToolCatalog`) — the same words the Inbox cheat sheet and Settings use.
    static func title(for action: ChatAgentAction) -> String {
        ActionToolCatalog.title(for: action.tool)
    }

    /// The per-tool lines (`ChatWire.ActionSummaryLines`).
    static func summaryLines(for action: ChatAgentAction) -> [String] {
        ActionSummaryLines.summaryLines(for: action)
    }

    /// The summary lines the card draws. A payload's empty lines are left out: a daemon one version behind sends no
    /// `args_display` and does not say whether it was clipped, which reads as one empty line. A row draws its lines as
    /// they are.
    static func bodyLines(for action: ChatAgentAction) -> [String] {
        let lines = summaryLines(for: action)
        return action.argsStored ? lines : lines.filter { !$0.isEmpty }
    }

    var sessionHolds: Bool { services.sessionHoldsCall?(action) ?? false }
    var state: ChatApprovalState? { services.state?(action) }
    var inFlight: Bool { state?.inFlight ?? false }
    var editsSlack: Bool { Self.editsSlack(action, services: services) }

    static func statusLabel(for action: ChatAgentAction, sessionHolds: Bool) -> String {
        if action.isSessionApplied {
            return ConnectorCallProposal.statusLabel(for: action, sessionHolds: sessionHolds)
        }
        switch action.status {
        case "pending": return "Awaiting your approval"
        case "approved": return "Approved"
        case "executing": return "Executing…"
        case "applied": return "Done"
        case "rejected": return "Rejected"
        case "failed": return "Failed"
        default: return action.status
        }
    }

    static func headerKind(_ status: String) -> ChatApprovalHeader.Kind {
        switch status {
        case "pending": .waiting
        case "applied": .done
        case "failed": .failed
        default: .neutral
        }
    }

    public var body: some View {
        // One args decode per render for a connector card.
        let connector = ConnectorCallProposal(action: action)
        let details = services.details?(action)
        style.approvalCard(AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
            if let contextLabel {
                contextLine(contextLabel)
            }
            style.approvalHeader(ChatApprovalHeader(
                title: services.title?(action) ?? Self.title(for: action),
                status: Self.statusLabel(for: action, sessionHolds: sessionHolds),
                external: action.external, kind: Self.headerKind(action.status)
            ))
            content(details: details, connector: connector)
            if let edit = Self.confluenceEdit(for: action) {
                ConfluenceEditChangesView(edit: edit)
            }
            if action.isPending, editsSlack, let slack = SlackSendProposal(action: action) {
                SlackSendEditor(proposal: slack, text: slackTextBinding(slack), pick: $slackPick)
                    .disabled(inFlight)
            }
            if !action.reason.isEmpty {
                Text(action.reason).font(.caption).foregroundStyle(.secondary).italic()
            }
            outcome
            links
            // A session-applied call's status line words its known errors.
            if !action.error.isEmpty, !ConnectorCallProposal.labelCarriesError(action) {
                Text(action.error).font(.caption).foregroundStyle(.red)
            }
            if let shown = Self.shownGestureError(state, action: action) {
                Label(shown, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("agentAction.gestureError")
            }
            // Only a FAILED row can have left a half-finished external write: Apply claims the row before it runs the
            // tool, so an `approved` one provably never reached Jira. (A Confluence edit is version-checked, so its
            // note says why a retry cannot double-write.)
            if action.status == "failed", action.external, !action.isSessionApplied {
                Text(action.tool == SlackSendProposal.tool ? Self.slackRetryNote : ConfluenceEdit.retryNote(for: action))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let accountID = Self.reconnectAccount(action, services: services), let reconnect = services.reconnectSlack {
                reconnectRow(accountID, reconnect)
            }
            if let slackMessage {
                Text(slackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentAction.slackMessage")
            }
            decision(connector: connector)
        }), outlined: outlined)
        // A row settled elsewhere drops the owner's unsent edits: nothing may approve stale args.
        .onChange(of: action.status) { _, _ in
            slackDraft = nil
            slackPick = nil
            connectorDraft = nil
        }
    }

    @ViewBuilder
    private func content(details: AnyView?, connector: ConnectorCallProposal?) -> some View {
        if let details {
            details
        } else if let connector {
            ConnectorCallDetails(proposal: connector, draft: connectorDraftBinding, approval: connectorApproval(connector))
                .disabled(inFlight)
        } else if let slack = SlackSendProposal(action: action) {
            SlackRecipientLine(proposal: slack)
            // The text is in the editor while the row can still be edited.
            if !(action.isPending && editsSlack) {
                style.approvalSlackText(slack.text)
            }
        } else {
            ForEach(Self.bodyLines(for: action), id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reconnectRow(_ accountID: Int64, _ reconnect: @escaping (Int64) async -> String?) -> some View {
        HStack(spacing: Spacing.regular) {
            Button("Reconnect Slack") {
                Task {
                    reconnecting = true
                    let failure = await reconnect(accountID)
                    reconnecting = false
                    slackMessage = failure.map { "Reconnect failed: \($0)" } ?? Self.reconnectDoneNote
                }
            }
            .disabled(reconnecting)
            .help("Sign in to Slack again to grant Watchtower permission to send, then Retry")
            .accessibilityIdentifier("agentAction.reconnectSlack")
            if reconnecting { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func contextLine(_ label: String) -> some View {
        if let onOpenContext {
            Button(label, action: onOpenContext)
                .approvalLinkStyle()
                .font(.caption)
                .help("Open the automation run")
                .accessibilityIdentifier("agentAction.contextLabel")
        } else {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("agentAction.contextLabel")
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if action.status == "applied", action.tool == ConfluenceEdit.tool {
            // The page is already linked above the diff; name the version the write produced instead of repeating
            // the link.
            Text("Saved as version \(action.resultString("version") ?? "?")").font(.callout)
        } else if action.status == "applied", let link = action.resultWebURL("url") {
            // Any tool that returns a url (+ optional label) links it — label, then key, then the url itself.
            // `resultWebURL` is http/https only, so a `javascript:`/`file:`/custom-scheme result never links.
            Link(action.resultString("label") ?? action.resultString("key") ?? link.absoluteString, destination: link)
                .font(.callout)
        } else if action.status == "applied", let id = action.resultString("target_id") {
            Text("Task #\(id) created").font(.callout)
        } else if action.status == "applied", let board = action.resultString("board_name") {
            Text("Board \(board) connected").font(.callout)
        }
        // A tool that applied but only partly says so in result.warning; the card is the owner's primary surface.
        if action.status == "applied", let warning = action.resultString("warning"), !warning.isEmpty {
            Text(warning).font(.caption).foregroundStyle(.orange)
        }
    }

    /// "Open" for what an applied action produced, and the Slack message a reaction command was placed on. A `.url`
    /// destination is not drawn here — `outcome`'s link already covers it — so this is the in-app path only.
    @ViewBuilder
    private var links: some View {
        let destination = action.destination
        let inApp: AgentActionDestination? = { if case .url = destination { return nil }; return destination }()
        let source = action.sourceMessageURL
        if inApp != nil || source != nil {
            HStack(spacing: Spacing.medium) {
                if let inApp, let open = services.openDestination {
                    Button(openLabel) { open(inApp) }
                        .approvalLinkStyle()
                }
                if let source {
                    Link("Slack message ↗", destination: source)
                }
            }
            .font(.callout)
        }
    }

    private var openLabel: String {
        if let key = action.resultString("key"), !key.isEmpty { return "Open \(key) →" }
        return "Open →"
    }
}
