import ChatWire
import SwiftUI
import WatchtowerCore

/// One agent_actions proposal as a chat card. Generic over the tool — the
/// argument rendering is the only per-tool code; state comes from the row
/// (Go owns transitions), so the card never guesses what happened.
struct AgentActionCardView: View {
    let action: AgentAction
    let inFlight: Bool
    let onApprove: () -> Void
    let onReject: () -> Void
    let onRetry: () -> Void
    /// Why this card's last Approve/Reject/Retry failed (`AgentActionFeed.rowErrors`).
    /// On a still-`pending` row whose APPROVE failed (e.g. SQLITE_BUSY, the
    /// row never moved) Approve becomes Retry, re-running the same approve; a
    /// failed Reject keeps its labels — Reject is its retry.
    var gestureError: AgentActionFeed.RowError?
    /// Follows an applied action to what it produced. Nil (the chat surfaces)
    /// hides the in-app "Open" button; a web destination (a created Jira
    /// issue) still links, since opening a browser needs no navigation.
    var onOpen: ((AgentActionDestination) -> Void)?
    /// Approve with the owner's card edits (`actions approve --patch`), for a
    /// tool whose card is editable (send_slack_message). Nil = the card offers
    /// no edits and Approve runs `onApprove`.
    var onApproveEdited: ((String) -> Void)?
    /// Re-consents a Slack account whose token lacks the send grant
    /// (`SlackSendProposal.reconnectAccountID`) and returns why it failed, nil
    /// on success. Nil hides the button.
    var onReconnectSlack: ((Int64) async -> String?)?
    /// Where the proposal came from, above the card — "⚙ <automation> · run
    /// #<n>" for a row an automation run proposed (`ActionStripViewModel.actionLabels`).
    /// Nil shows nothing.
    var contextLabel: String?
    /// Opens what `contextLabel` names (the automation's card, run open).
    /// Nil renders the label as plain text.
    var onOpenContext: (() -> Void)?
    /// The editor chat's newest draft text (the Draft panel's); a pending
    /// `save_automation` card whose text differs warns. nil elsewhere.
    var latestDraftText: String?
    /// The editor chat's cached dry runs, recipe text → the sessions each
    /// starts (`AutomationDraftPanelModel.dryRunSessions`); the save card
    /// shows the ones of its own text. Unused where `latestDraftText` is nil.
    var draftSessions: [String: AutomationDryRunSessions] = [:]
    /// Dismiss on a session call whose outcome is unknown
    /// (`ConnectorCallProposal.awaitsDismissal`), which waits on the Inbox
    /// badge until then. Nil hides the button.
    var onDismiss: (() -> Void)?
    /// A session-applied call (`claude_ai_connector_call`): whether the live
    /// chat session that proposed it still waits on it
    /// (`ConnectorCallProposal.sessionHolds`). False shows "Chat session
    /// ended" and offers no Approve, so an approval nobody can run never
    /// reads as a call about to run. Unused for every other tool.
    var sessionHoldsCall = false
    /// The Inbox target button's state of this `create_target` proposal
    /// (Inbox builder A, the resolver of plan Task 15); nil elsewhere. When
    /// it is `.stuck` the card draws the shared "Didn't finish" line with
    /// **Try again** in place of its Approve/Retry row. Try again runs
    /// `onRetry`, which the host makes `actions apply` on an approved row
    /// and `actions apply --force` on an executing one — the same row.
    var targetButtonState: ArtifactTargetButtonState?
    /// False on an older proposal of an Inbox target button whose newest row
    /// is another one: Try again is offered only on the newest row (the CLI
    /// refuses the older one with exit 3).
    var offersRetry = true

    /// The pending Slack send's edited text (nil = untouched) and workspace pick.
    @State private var slackDraft: String?
    @State private var slackPick: Int?
    /// The card's own Slack gestures: an edit that could not be encoded, and
    /// the outcome of Reconnect Slack (shown here, not only in Settings).
    @State private var slackMessage: String?
    @State private var reconnecting = false
    /// The connector call's input while the owner edits it; nil = not editing.
    @State private var connectorDraft: String?

    /// The shared human name (`ReactionToolCatalog`) — the same words the
    /// Inbox cheat sheet and the Settings reaction dictionary use.
    static func title(for action: AgentAction) -> String {
        ReactionToolCatalog.title(for: action.tool)
    }

    /// The per-tool lines (`ChatWire.ActionSummaryLines`, shared with the iPhone).
    static func summaryLines(for action: AgentAction) -> [String] {
        ActionSummaryLines.summaryLines(for: action)
    }

    /// The Slack send this card may edit: only where the host wired
    /// `onApproveEdited` (the main chat and the Inbox strip).
    private var editableSlack: SlackSendProposal? {
        onApproveEdited == nil ? nil : SlackSendProposal(action: action)
    }

    /// After a sign-in that reported no error — which a cancelled one does
    /// not either, and a grant Slack still refused send for neither.
    static let reconnectDoneNote = "Sign-in closed. Press Retry — if sending is still refused, Slack has not "
        + "allowed it for this workspace yet (its app settings or admin must)."

    /// The owner's edits travel with the approval; no edits is a plain
    /// approve. An edit that cannot be encoded is reported, never dropped
    /// for the original draft.
    private func approveSlack(_ slack: SlackSendProposal, text: String) {
        do {
            switch try slack.approval(text: text, pick: slackPick) {
            case .edited(let patch): onApproveEdited?(patch)
            case .plain: onApprove()
            }
            slackMessage = nil
        } catch {
            slackMessage = "Could not save your edits: \(error.localizedDescription)"
        }
    }

    private func slackTextBinding(_ slack: SlackSendProposal) -> Binding<String> {
        Binding(get: { slackDraft ?? slack.text }, set: { slackDraft = $0 })
    }

    private var statusLabel: String {
        if action.isSessionApplied {
            return ConnectorCallProposal.statusLabel(for: action, sessionHolds: sessionHoldsCall)
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

    var body: some View {
        // One args decode per render for a save_automation card.
        let save = action.tool == SaveAutomationCardModel.tool ? SaveAutomationCardModel(action: action) : nil
        let connector = ConnectorCallProposal(action: action)
        VStack(alignment: .leading, spacing: 8) {
            if let contextLabel {
                contextLine(contextLabel)
            }
            header(title: save?.title ?? Self.title(for: action))
            if let save {
                SaveAutomationCardDetails(model: save, actionID: action.id,
                                          differsFromDraft: action.isPending && save.differsFromDraft(latestDraftText),
                                          sessions: save.draftSessions(latestDraftText: latestDraftText,
                                                                       isPending: action.isPending,
                                                                       dryRunSessions: draftSessions))
            } else if let connector {
                ConnectorCallDetails(proposal: connector, draft: connectorDraftBinding,
                                     approval: connectorApproval(connector))
                    .disabled(inFlight)
            } else if let slack = SlackSendProposal(action: action) {
                SlackRecipientLine(proposal: slack)
                // The text is in the editor while the row can still be edited.
                if !(action.isPending && editableSlack != nil) {
                    Text(slack.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Self.summaryLines(for: action), id: \.self) { line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let edit = Self.confluenceEdit(for: action) {
                ConfluenceEditChangesView(edit: edit)
            }
            if action.isPending, let slack = editableSlack {
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
            if let shownGestureError {
                Label(shownGestureError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("agentAction.gestureError")
            }
            // Only a FAILED row can have left a half-finished external write:
            // Apply claims the row before it runs the tool, so an `approved`
            // one provably never reached Jira. (A Confluence edit is version-
            // checked, so its note says why a retry cannot double-write.)
            if action.status == "failed", action.external, !action.isSessionApplied {
                Text(action.tool == SlackSendProposal.tool ? Self.slackRetryNote() : Self.retryNote(for: action))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let accountID = SlackSendProposal.reconnectAccountID(action), let onReconnectSlack {
                HStack(spacing: 8) {
                    Button("Reconnect Slack") {
                        Task {
                            reconnecting = true
                            let failure = await onReconnectSlack(accountID)
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
            if let slackMessage {
                Text(slackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentAction.slackMessage")
            }
            actions(connector: connector)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The gesture's failure, unless the row itself already says it — a failed
    /// apply lands in the row's `error` too, possibly wrapped by the CLI — or
    /// the row has since been decided elsewhere (a terminal card needs no
    /// retry, and a stale red line would contradict its status).
    private var shownGestureError: String? {
        guard let message = gestureError?.message, !message.isEmpty else { return nil }
        // An applied create_track's failed `tracks start` stays on its card.
        if gestureError?.verb == AgentActionFeed.startVerb { return message }
        guard !action.isTerminal else { return nil }
        if !action.error.isEmpty, message.contains(action.error) || action.error.contains(message) { return nil }
        return message
    }

    @ViewBuilder
    private func contextLine(_ label: String) -> some View {
        if let onOpenContext {
            Button(label, action: onOpenContext)
                .buttonStyle(.link)
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

    private func header(title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: action.external ? "arrow.up.right.square" : "checklist")
                .foregroundStyle(Color.accentColor)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("agentAction.status")
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if action.status == "applied", action.tool == Self.confluenceEditTool {
            // The page is already linked above the diff; name the version
            // the write produced instead of repeating the link.
            Text("Saved as version \(action.resultString("version") ?? "?")").font(.callout)
        } else if action.status == "applied", let link = action.resultWebURL("url") {
            // Generic: any tool that returns a url (+ optional label) links it —
            // label, then key, then the url itself (spec 2026-09-26 §8).
            // `resultWebURL` is the same http/https-only check
            // `AgentActionDestination.destination` uses, so a `javascript:`/
            // `file:`/custom-scheme result never renders as a clickable link.
            Link(action.resultString("label") ?? action.resultString("key") ?? link.absoluteString, destination: link).font(.callout)
        } else if action.status == "applied", let id = action.resultString("target_id") {
            Text("Task #\(id) created").font(.callout)
        } else if action.status == "applied", let board = action.resultString("board_name") {
            Text("Board \(board) connected").font(.callout)
        }
        // A tool that applied but only partly (create_jira_issue's mirror,
        // connect_jira_board's first profile) says so in result.warning; the
        // card is the owner's primary surface, so the warning must show here,
        // not only in `watchtower actions show`.
        if action.status == "applied", let warning = action.resultString("warning"), !warning.isEmpty {
            Text(warning).font(.caption).foregroundStyle(.orange)
        }
    }

    /// "Open" for what an applied action produced, and the Slack message a
    /// reaction command was placed on. A `.url` destination is NOT rendered
    /// here — `outcome`'s generic url+label link already covers it (both
    /// derive from the same `result.url`), so this stays the in-app-navigation
    /// path only (`onOpen`).
    @ViewBuilder
    private var links: some View {
        let destination = action.destination
        let inApp: AgentActionDestination? = { if case .url = destination { return nil }; return destination }()
        let source = action.sourceMessageURL
        if inApp != nil || source != nil {
            HStack(spacing: 12) {
                if let inApp, let onOpen {
                    Button(openLabel) { onOpen(inApp) }
                        .buttonStyle(.link)
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

    /// The editor's binding while the owner edits the input of a call that
    /// can still be approved; once Approve is gone the input is read-only.
    private var connectorDraftBinding: Binding<String>? {
        guard ConnectorCallProposal.canApprove(action, sessionHolds: sessionHoldsCall), connectorDraft != nil else {
            return nil
        }
        return Binding(get: { connectorDraft ?? "" }, set: { connectorDraft = $0 })
    }

    private func connectorApproval(_ connector: ConnectorCallProposal) -> ConnectorCallProposal.Approval? {
        connector.approval(editedInput: connectorDraft ?? connector.inputJSON)
    }

    /// Approve for a connector call: plain while the input is untouched,
    /// with the edited input otherwise (`onApproveEdited`). A call the card
    /// cannot read gets Reject only, and says why.
    @ViewBuilder
    private func connectorButtons(_ connector: ConnectorCallProposal?) -> some View {
        if let connector, ConnectorCallProposal.canApprove(action, sessionHolds: sessionHoldsCall) {
            let approval = connectorApproval(connector)
            Button(gestureError?.isApprove == true ? "Retry" : "Approve") {
                switch approval {
                case .plain?: onApprove()
                case .edited(let patch)?: onApproveEdited?(patch)
                case nil: break // disabled below
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(approval == nil)
            if onApproveEdited != nil {
                if connectorDraft == nil {
                    Button("Edit Input") { connectorDraft = connector.inputJSON }
                        .accessibilityIdentifier("agentAction.connectorEdit")
                } else {
                    Button("Revert") { connectorDraft = nil }
                        .accessibilityIdentifier("agentAction.connectorRevert")
                }
            }
        } else if connector == nil {
            Text(ConnectorCallProposal.unreadableNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(connector: ConnectorCallProposal?) -> some View {
        switch Self.targetRow(targetButtonState, status: action.status) {
        case .stuck:
            ArtifactTargetStuckLine(onTryAgain: onRetry)
                .controlSize(.small)
                .disabled(inFlight)
                .accessibilityIdentifier("agentAction.targetStuck")
        case .inFlight:
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("agentAction.targetCreating")
        case .decision:
            decisionRow(connector: connector)
        }
    }

    /// What an Inbox target button's proposal draws in place of the
    /// decision row: an approved or executing row the button calls stuck,
    /// or whose Try again failed without moving it, offers Try again on the
    /// same row; one in flight shows progress only (no Retry while our own
    /// or a recent apply may still land). Every other row keeps its row.
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

    @ViewBuilder
    private func decisionRow(connector: ConnectorCallProposal?) -> some View {
        HStack {
            // A claimed row is being executed by another process: there is
            // nothing the owner can decide about it until it lands. (A
            // session call whose session is gone will not land: no spinner.)
            if action.isExecuting {
                if !action.isSessionApplied || sessionHoldsCall { ProgressView().controlSize(.small) }
            } else {
                if action.isPending {
                    switch Self.pendingApproval(for: action, editsSlack: editableSlack != nil) {
                    case .session:
                        connectorButtons(connector)
                    case let .slack(slack):
                        let text = slackDraft ?? slack.text
                        Button(gestureError?.isApprove == true ? "Retry" : "Approve & send") {
                            approveSlack(slack, text: text)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!slack.canApprove(text: text, pick: slackPick))
                    case .plain:
                        Button(gestureError?.isApprove == true ? "Retry" : "Approve", action: onApprove)
                            .buttonStyle(.borderedProminent)
                    case .none:
                        EmptyView()
                    }
                    Button("Reject", action: onReject)
                } else {
                    switch Self.settledOffer(for: action) {
                    case .retry:
                        if offersRetry { Button("Retry", action: onRetry) }
                    case .dismiss:
                        if let onDismiss {
                            Text(ConnectorCallProposal.dismissNote).font(.caption).foregroundStyle(.secondary)
                            Button("Dismiss", action: onDismiss)
                                .help("Take this call off the Inbox badge")
                                .accessibilityIdentifier("agentAction.dismissOutcomeUnknown")
                        }
                    case .none:
                        EmptyView()
                    }
                }
                if inFlight { ProgressView().controlSize(.small) }
            }
        }
        .disabled(inFlight)
    }
}

/// The `save_automation` card's body (spec §11): file, trigger, permissions
/// with the widening ones marked "+", outputs, budget, missed runs,
/// concurrency, the assistant's dry-run summary, and the code it confirms —
/// the whole recipe for a new one, the diff against the saved file for an
/// edit.
private struct SaveAutomationCardDetails: View {
    let model: SaveAutomationCardModel
    let actionID: Int64
    let differsFromDraft: Bool
    let sessions: SaveAutomationCardModel.DraftSessions

    /// Optional: a card rendered outside the app's window (a design shot)
    /// names the workbench by id.
    @Environment(AppState.self) private var appState: AppState?

    var body: some View {
        Text(model.scopeLine { id in
            appState?.workbenchesViewModel?.summaries.first { $0.project.id == id }?.project.name
        })
        .font(.callout)
        if differsFromDraft {
            Label(SaveAutomationCardModel.draftMismatchWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(.callout)
                .foregroundStyle(line.hasPrefix("+ ") ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let summary = model.dryRunSummary {
            Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        switch sessions {
        case .hidden:
            EmptyView()
        case .unmatched:
            note(SaveAutomationCardModel.unmatchedSessionsLine)
        case .readRecipe:
            note(SaveAutomationCardModel.readRecipeLine)
        case let .shown(run):
            if !run.sessions.isEmpty { AutomationSessionPromptsBlock(sessions: run.sessions) }
            if run.stoppedEarly { note(SaveAutomationCardModel.stoppedEarlyLine) }
        }
        if let text = model.newRecipeText {
            // A new recipe has nothing to diff against: its whole text is
            // what Approve confirms (Review Focus #2).
            RecipeTextDisclosure(title: SaveAutomationCardModel.recipeDisclosureTitle(text), text: text,
                                 modelID: -actionID, contentHash: "save-\(actionID)", slug: "recipe")
                .font(.callout)
        }
        if let diff = model.diff {
            DisclosureGroup(diff.isIdentical ? "No change to the recipe text" : "Show changes") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in row(line) }
                }
            }
            .font(.callout)
            .disabled(diff.isIdentical)
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "questionmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ line: OwnerAskSnapshotDiff.Line) -> some View {
        let (mark, text, tint): (String, String, Color?) = switch line {
        case let .same(text): (" ", text, nil)
        case let .added(text): ("+", text, .green)
        case let .removed(text): ("−", text, .red)
        }
        return HStack(alignment: .top, spacing: 6) {
            Text(mark).foregroundStyle(tint ?? .secondary).frame(width: 10)
            Text(text.isEmpty ? " " : text).foregroundStyle(tint == nil ? .secondary : .primary)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { $0.opacity(0.12) } ?? .clear)
        .textSelection(.enabled)
    }
}
