import ChatWire
import SwiftUI
import WatchtowerDesign

/// The card's decision rules in one place, pure so both devices' tests pin them: the decision row draws from them, and
/// the Mac's Inbox row with this proposal as its `ref` offers the same presses.
extension AgentActionCard {
    /// How a pending row offers Approve.
    public enum PendingApproval: Equatable {
        /// A session-applied call: Approve while the chat session holds it and the card can read it.
        case session
        /// A Slack send the owner can edit: Approve & send once a workspace is chosen and the text is sendable.
        case slack(SlackSendProposal)
        case plain
        /// No Approve: an unreadable Confluence edit (F7), or a card with no digest to pin (AGENT-07).
        case none
    }

    /// What a row no longer pending offers.
    public enum SettledOffer: Equatable {
        case retry
        /// A session call whose outcome is unknown (`ConnectorCallProposal.awaitsDismissal`).
        case dismiss
        case none
    }

    /// Whether the pending decision buttons show, and whether they are live.
    public enum Availability: Equatable {
        case live
        /// Shown but off: no answer can go now (offline, an answer on its way, a CLI call in flight).
        case disabled
        /// Not shown: this device may not answer (the phone without the `permissions` grant).
        case hidden
    }

    public static func pendingApproval(for action: ChatAgentAction, editsSlack: Bool) -> PendingApproval {
        if action.isSessionApplied { return .session }
        // AGENT-07: an approve pins the digest of the args the owner saw. A card with none (a payload from a daemon
        // that sends no digest) offers no Approve rather than hash its display text.
        guard action.approveDigest != nil else { return .none }
        // A Slack send still waiting for its workspace on a screen that cannot pick: Go would refuse the approve.
        if slackNeedsPick(action, editsSlack: editsSlack) { return .none }
        if editsSlack, let slack = SlackSendProposal(action: action) { return .slack(slack) }
        return ConfluenceEdit.canApprove(action) ? .plain : .none
    }

    public static func settledOffer(for action: ChatAgentAction) -> SettledOffer {
        if action.canRetry { return .retry }
        return ConnectorCallProposal.awaitsDismissal(action) ? .dismiss : .none
    }

    /// The settled offer this card draws: none where its capability is not wired (the phone has no Retry or Dismiss).
    static func shownSettledOffer(
        for action: ChatAgentAction, services: ChatApprovalServices, offersRetry: Bool
    ) -> SettledOffer {
        switch settledOffer(for: action) {
        case .retry: services.retry != nil && offersRetry ? .retry : .none
        case .dismiss: services.dismiss != nil ? .dismiss : .none
        case .none: .none
        }
    }

    /// What a row no longer pending draws: its offer, the note that says where to act instead (no grant, an older hub;
    /// mobile Inbox spec §12.4), or nothing.
    public enum SettledRow: Equatable {
        case offer(SettledOffer)
        case note(String)
        case none
    }

    public static func settledRow(
        for action: ChatAgentAction, services: ChatApprovalServices, offersRetry: Bool, state: ChatApprovalState?
    ) -> SettledRow {
        let offered: SettledOffer = switch settledOffer(for: action) {
        case .retry: offersRetry ? .retry : .none
        case let other: other
        }
        if offered != .none, let note = state?.settledNote { return .note(note) }
        let shown = shownSettledOffer(for: action, services: services, offersRetry: offersRetry)
        return shown == .none ? .none : .offer(shown)
    }

    /// The state line under the row: on a pending row, and on a settled one that offers (or notes) Retry or Dismiss.
    public static func shownLine(
        for action: ChatAgentAction, services: ChatApprovalServices, offersRetry: Bool, state: ChatApprovalState?
    ) -> String? {
        guard let line = state?.line else { return nil }
        if action.isPending { return line }
        return settledRow(for: action, services: services, offersRetry: offersRetry, state: state) == .none ? nil : line
    }

    public static func availability(_ state: ChatApprovalState?) -> Availability {
        guard let state else { return .live }
        if !state.showsButtons { return .hidden }
        return state.canAnswer && !state.inFlight ? .live : .disabled
    }

    /// The Slack editor and workspace pick show: the screen takes edits, and the args reached this device whole.
    static func editsSlack(_ action: ChatAgentAction, services: ChatApprovalServices) -> Bool {
        services.approveEdited && SlackSendProposal(action: action)?.editable == true
    }

    /// A Slack send whose workspace is not chosen yet (candidates and no target, or no recipient at all) on a screen
    /// without the editor's pick (the phone, a Mac surface that takes no edits). The card says where to choose
    /// (`ChatHostText.chooseSlackWorkspace`) and offers no Approve, as the Mac's Inbox row (`rowButtons`) does.
    static func slackNeedsPick(_ action: ChatAgentAction, editsSlack: Bool) -> Bool {
        guard action.tool == SlackSendProposal.tool, !editsSlack, !action.argsClipped else { return false }
        if let slack = SlackSendProposal(action: action) { return slack.target == nil }
        return action.argString("text") != nil
    }

    /// The line the card shows for a Slack send's recipient when there is nothing to pick with: the host's words.
    static func slackChooseLine(_ action: ChatAgentAction, editsSlack: Bool, hostText: ChatHostText) -> String? {
        slackNeedsPick(action, editsSlack: editsSlack) ? hostText.chooseSlackWorkspace : nil
    }

    /// A connector call's Edit Input shows: the screen takes edits, the args are whole and the call can be approved.
    static func connectorEditable(_ action: ChatAgentAction, services: ChatApprovalServices, sessionHolds: Bool) -> Bool {
        services.approveEdited && action.argsComplete && ConnectorCallProposal(action: action) != nil
            && ConnectorCallProposal.canApprove(action, sessionHolds: sessionHolds)
    }

    /// The pinned Confluence edit, memoized per row version; nil when the args did not reach this device whole.
    static func confluenceEdit(for action: ChatAgentAction) -> ConfluenceEdit? {
        action.argsComplete ? ConfluenceEdit.proposal(for: action) : nil
    }

    /// The Slack account Reconnect Slack re-consents; nil hides the button (or the screen cannot reconnect).
    static func reconnectAccount(_ action: ChatAgentAction, services: ChatApprovalServices) -> Int64? {
        services.reconnectSlack == nil ? nil : SlackSendProposal.reconnectAccountID(action)
    }

    /// The gesture's failure, unless the row itself already says it — a failed apply lands in the row's `error` too,
    /// possibly wrapped by the CLI — or the row has since been decided elsewhere (a terminal card needs no retry, and a
    /// stale red line would contradict its status).
    static func shownGestureError(_ state: ChatApprovalState?, action: ChatAgentAction) -> String? {
        guard let message = state?.gestureError, !message.isEmpty else { return nil }
        if state?.gestureErrorOutlivesRow == true { return message }
        guard !action.isTerminal else { return nil }
        if !action.error.isEmpty, message.contains(action.error) || action.error.contains(message) { return nil }
        return message
    }

    /// A card the running turn waits on (its action is pending in the turn that runs): outlined.
    static func isAwaited(_ action: ChatAgentAction, runningTurnID: String?) -> Bool {
        action.isPending && !action.turnID.isEmpty && action.turnID == runningTurnID
    }

    static let approveLabel = "Approve"
    static let rejectLabel = "Reject"
    static let retryLabel = "Retry"
    static let dismissLabel = "Dismiss"

    // MARK: - The row

    /// Which row the card draws under its body: a Not delivered press's named Retry wins over everything (its
    /// outbox action is the one to resend, mobile Inbox spec §12.4), then the screen's own row (the Inbox target
    /// button's), then the card's decision row.
    public enum DecisionRowKind: Equatable {
        case undelivered
        case custom
        case standard
    }

    public static func decisionRowKind(
        for action: ChatAgentAction, state: ChatApprovalState?, hasOverride: Bool
    ) -> DecisionRowKind {
        if state?.undelivered != nil, !action.isTerminal { return .undelivered }
        return hasOverride ? .custom : .standard
    }

    @ViewBuilder
    func decision(connector: ConnectorCallProposal?) -> some View {
        let custom = services.decisionOverride?(action)
        switch Self.decisionRowKind(for: action, state: state, hasOverride: custom != nil) {
        case .undelivered:
            if let undelivered = state?.undelivered { undeliveredRow(undelivered) }
        case .custom:
            custom
        case .standard:
            decisionRow(connector: connector)
            if let line = Self.shownLine(for: action, services: services, offersRetry: offersRetry, state: state) {
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
    }

    @ViewBuilder
    private func decisionRow(connector: ConnectorCallProposal?) -> some View {
        let availability = Self.availability(state)
        HStack {
            // A claimed row is being executed by another process: there is nothing the owner can decide about it
            // until it lands. (A session call whose session is gone will not land: no spinner.)
            if action.isExecuting {
                if !action.isSessionApplied || sessionHolds { ProgressView().controlSize(.small) }
            } else {
                if action.isPending {
                    if availability != .hidden { pendingButtons(connector: connector) }
                } else {
                    settledButtons
                }
                if inFlight { ProgressView().controlSize(.small) }
            }
        }
        .disabled(availability == .disabled)
    }

    /// Not delivered: the line in red and the named Retry, the row's one button.
    private func undeliveredRow(_ undelivered: ChatApprovalState.Undelivered) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(undelivered.line, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Tone.error)
                .accessibilityIdentifier("agentAction.undelivered")
            style.approvalButton(undelivered.retryTitle, prominent: true) { services.resend?(action) }
                .accessibilityIdentifier("agentAction.resend")
        }
    }

    private var approveTitle: String {
        state?.approveFailed == true ? Self.retryLabel : Self.approveLabel
    }

    @ViewBuilder
    private func pendingButtons(connector: ConnectorCallProposal?) -> some View {
        if let note = state?.approveNote {
            approveNoteText(note)
        } else {
            approveButton(connector: connector)
        }
        style.approvalButton(Self.rejectLabel, prominent: false) { services.decide(action, .reject) }
            .accessibilityIdentifier("chat.approval.reject")
    }

    @ViewBuilder
    private func approveButton(connector: ConnectorCallProposal?) -> some View {
        switch Self.pendingApproval(for: action, editsSlack: editsSlack) {
        case .session:
            connectorButtons(connector)
        case let .slack(slack):
            let text = drafts.slack ?? slack.text
            style.approvalButton(state?.approveFailed == true ? Self.retryLabel : "Approve & send", prominent: true) {
                approveSlack(slack, text: text)
            }
            .disabled(!slack.canApprove(text: text, pick: drafts.pick))
            .accessibilityIdentifier("chat.approval.approve")
        case .plain:
            style.approvalButton(approveTitle, prominent: true) {
                services.decide(action, .approve(patch: nil))
            }
            .accessibilityIdentifier("chat.approval.approve")
        case .none:
            EmptyView()
        }
    }

    /// Approve's note in its place (no grant, a draft only the Mac opens).
    private func approveNoteText(_ note: String) -> some View {
        Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("agentAction.approveNote")
    }

    @ViewBuilder
    private var settledButtons: some View {
        switch Self.settledRow(for: action, services: services, offersRetry: offersRetry, state: state) {
        case .offer(.retry):
            Button(Self.retryLabel) { services.retry?(action) }
                .accessibilityIdentifier("agentAction.retry")
        case .offer(.dismiss):
            Text(ConnectorCallProposal.dismissNote).font(.caption).foregroundStyle(.secondary)
            Button(Self.dismissLabel) { services.dismiss?(action) }
                .help("Take this call off the Inbox badge")
                .accessibilityIdentifier("agentAction.dismissOutcomeUnknown")
        case let .note(note):
            Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("agentAction.settledNote")
        case .offer(.none), .none:
            EmptyView()
        }
    }

    /// Approve for a connector call: plain while the input is untouched, with the edited input otherwise. A call the
    /// card cannot read gets Reject only, and says why; one whose args reached this device clipped still approves,
    /// pinned to the digest of what Go stored.
    @ViewBuilder
    private func connectorButtons(_ connector: ConnectorCallProposal?) -> some View {
        let readable = connector != nil || action.argsClipped
        if readable, ConnectorCallProposal.canApprove(action, sessionHolds: sessionHolds), action.approveDigest != nil {
            let approval = connector.map(connectorApproval) ?? .plain
            style.approvalButton(approveTitle, prominent: true) {
                switch approval {
                case .plain?: services.decide(action, .approve(patch: nil))
                case .edited(let patch)?: services.decide(action, .approve(patch: patch))
                case nil: break // disabled below
                }
            }
            .disabled(approval == nil)
            .accessibilityIdentifier("chat.approval.approve")
            if let connector, Self.connectorEditable(action, services: services, sessionHolds: sessionHolds) {
                if drafts.connector == nil {
                    Button("Edit Input") { editDrafts { $0.connector = connector.inputJSON } }
                        .accessibilityIdentifier("agentAction.connectorEdit")
                } else {
                    Button("Revert") { editDrafts { $0.connector = nil } }
                        .accessibilityIdentifier("agentAction.connectorRevert")
                }
            }
        } else if !readable {
            Text(ConnectorCallProposal.unreadableNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The editor's binding while the owner edits the input of a call that can still be approved; once Approve is
    /// gone the input is read-only.
    var connectorDraftBinding: Binding<String>? {
        guard Self.connectorEditable(action, services: services, sessionHolds: sessionHolds), drafts.connector != nil else {
            return nil
        }
        return Binding(get: { drafts.connector ?? "" }, set: { input in editDrafts { $0.connector = input } })
    }

    func connectorApproval(_ connector: ConnectorCallProposal) -> ConnectorCallProposal.Approval? {
        connector.approval(editedInput: drafts.connector ?? connector.inputJSON)
    }
}
