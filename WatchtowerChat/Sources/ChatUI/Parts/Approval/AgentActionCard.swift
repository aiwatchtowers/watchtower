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

    /// The engine's title, for a card drawn from its payload whose tool the catalog does not know.
    let fallbackTitle: String?

    @Environment(\.chatUIStyle) var style
    @Environment(\.chatHostText) var hostText

    /// The owner's unsent edits, stamped with the row they were made on (`draftKey`): once the row settles or its args
    /// change, they are dropped, so nothing approves args the owner did not see.
    @State var storedDrafts: CardDrafts?
    /// The card's own Slack gestures: an edit that could not be encoded, and the outcome of Reconnect Slack.
    @State var slackMessage: String?
    @State private var reconnecting = false

    public init(
        action: ChatAgentAction,
        services: ChatApprovalServices,
        contextLabel: String? = nil,
        onOpenContext: (() -> Void)? = nil,
        outlined: Bool = false,
        offersRetry: Bool = true
    ) {
        self.init(action: action, services: services, contextLabel: contextLabel, onOpenContext: onOpenContext,
                  outlined: outlined, offersRetry: offersRetry, fallbackTitle: nil, drafts: nil)
    }

    /// `fallbackTitle`: the payload's title (ApprovalPartView). `drafts`: edits a test starts the card with.
    init(
        action: ChatAgentAction,
        services: ChatApprovalServices,
        contextLabel: String? = nil,
        onOpenContext: (() -> Void)? = nil,
        outlined: Bool = false,
        offersRetry: Bool = true,
        fallbackTitle: String?,
        drafts: CardDrafts?
    ) {
        self.action = action
        self.services = services
        self.contextLabel = contextLabel
        self.onOpenContext = onOpenContext
        self.outlined = outlined
        self.offersRetry = offersRetry
        self.fallbackTitle = fallbackTitle
        _storedDrafts = State(initialValue: drafts)
    }

    /// The owner's unsent edits on one row: the Slack text and workspace pick, the connector input.
    struct CardDrafts: Equatable {
        let key: String
        var slack: String?
        var pick: Int?
        var connector: String?
    }

    /// The row an edit was made on: its id, status and args. Edits made under another key are not this row's.
    static func draftKey(_ action: ChatAgentAction) -> String {
        "\(action.id)|\(action.status)|\(action.argsSHA256)|\(action.argsJSON.utf8.count)"
    }

    /// The edits that belong to the row as it is now; empty when they were made on another state of it.
    var drafts: CardDrafts {
        let key = Self.draftKey(action)
        if let storedDrafts, storedDrafts.key == key { return storedDrafts }
        return CardDrafts(key: key)
    }

    func editDrafts(_ change: (inout CardDrafts) -> Void) {
        var next = drafts
        change(&next)
        storedDrafts = next
    }

    var slackPickBinding: Binding<Int?> {
        Binding(get: { drafts.pick }, set: { pick in editDrafts { $0.pick = pick } })
    }

    /// The card's title: the screen's own (save_automation), else the catalog's; a payload-drawn card of a tool the
    /// catalog does not know keeps the engine's title rather than the raw tool id.
    static func cardTitle(for action: ChatAgentAction, fallback: String?) -> String {
        if !action.argsStored, ActionToolCatalog.info(for: action.tool) == nil, let fallback, !fallback.isEmpty {
            return fallback
        }
        return title(for: action)
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
    static let payloadLineLimit = 12

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
                title: services.title?(action) ?? Self.cardTitle(for: action, fallback: fallbackTitle),
                status: Self.statusLabel(for: action, sessionHolds: sessionHolds),
                external: action.external, kind: Self.headerKind(action.status)
            ))
            content(details: details, connector: connector)
            if let edit = Self.confluenceEdit(for: action) {
                ConfluenceEditChangesView(edit: edit)
            }
            if action.isPending, editsSlack, let slack = SlackSendProposal(action: action) {
                SlackSendEditor(proposal: slack, text: slackTextBinding(slack), pick: slackPickBinding)
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
    }

    @ViewBuilder
    private func content(details: AnyView?, connector: ConnectorCallProposal?) -> some View {
        if let details {
            details
        } else if let connector {
            ConnectorCallDetails(proposal: connector, draft: connectorDraftBinding, approval: connectorApproval(connector))
                .disabled(inFlight)
        } else if let choose = Self.slackChooseLine(action, editsSlack: editsSlack, hostText: hostText) {
            // Nothing to pick with here: say where to choose, and offer no Approve (`pendingApproval`).
            Text(choose).font(.callout).fixedSize(horizontal: false, vertical: true)
            style.approvalSlackText(SlackSendProposal(action: action)?.text ?? action.argString("text") ?? "")
        } else if let slack = SlackSendProposal(action: action) {
            SlackRecipientLine(proposal: slack)
            // The text is in the editor while the row can still be edited.
            if !(action.isPending && editsSlack) {
                style.approvalSlackText(slack.text)
            }
        } else {
            ForEach(Self.bodyLines(for: action), id: \.self) { line in
                // A payload's raw args can run to 4000 characters: bounded, as the phone's card always was.
                Text(line)
                    .font(.callout)
                    .lineLimit(action.argsStored ? nil : Self.payloadLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
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
