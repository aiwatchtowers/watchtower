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
    /// (`SlackSendProposal.reconnectAccountID`). Nil hides the button.
    var onReconnectSlack: ((Int64) -> Void)?

    /// The pending Slack send's edited text (nil = untouched) and workspace pick.
    @State private var slackDraft: String?
    @State private var slackPick: Int?

    /// The shared human name (`ReactionToolCatalog`) — the same words the
    /// Inbox cheat sheet and the Settings reaction dictionary use.
    static func title(for action: AgentAction) -> String {
        ReactionToolCatalog.title(for: action.tool)
    }

    static func summaryLines(for action: AgentAction) -> [String] {
        switch action.tool {
        case "create_target":
            var lines = [action.argString("text") ?? ""]
            var meta: [String] = []
            if let due = action.argString("due"), !due.isEmpty { meta.append("Due: \(due)") }
            if let p = action.argString("priority"), !p.isEmpty { meta.append("Priority: \(p)") }
            if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
            if let intent = action.argString("intent"), !intent.isEmpty { lines.append("Why: \(intent)") }
            return lines
        case "create_jira_issue":
            var lines = ["Project: \(action.argString("project_key") ?? "?") · \(action.argString("issue_type") ?? "?")"]
            lines.append("Summary: \(action.argString("summary") ?? "")")
            if let d = action.argString("description"), !d.isEmpty { lines.append("Description: \(d)") }
            if let l = action.argString("labels"), !l.isEmpty { lines.append("Labels: \(l)") }
            if let p = action.argString("priority"), !p.isEmpty { lines.append("Priority: \(p)") }
            return lines
        default:
            // The Confluence edit first: its args carry the whole new page
            // storage, and every other branch would decode them per render.
            return confluenceEditSummaryLines(for: action) ?? waveTwoSummaryLines(for: action)
                ?? jiraIssueWriteSummaryLines(for: action) ?? slackSummaryLines(for: action) ?? [action.argsJSON]
        }
    }

    /// The four existing-issue Jira writes (spec 2026-09-26 §8); nil for any
    /// other tool — decided on the tool name alone, before any args decode.
    private static func jiraIssueWriteSummaryLines(for action: AgentAction) -> [String]? {
        switch action.tool {
        case "add_jira_comment":
            return ["Issue: \(issueKey(action))", action.argString("body") ?? ""]
        case "transition_jira_issue":
            return ["Issue: \(issueKey(action)) → \(action.argString("status") ?? "?")"]
        case "assign_jira_issue":
            return assignSummaryLines(for: action, key: issueKey(action))
        case "update_jira_issue":
            var lines = ["Issue: \(issueKey(action))"]
            let fields: [(String, String)] = [("summary", "Summary"), ("priority", "Priority"),
                                              ("labels_add", "Add labels"), ("labels_remove", "Remove labels"),
                                              ("due_date", "Due")]
            for (arg, title) in fields {
                if let value = action.argString(arg), !value.isEmpty { lines.append("\(title): \(value)") }
            }
            return lines
        default:
            return nil
        }
    }

    private static func issueKey(_ action: AgentAction) -> String {
        action.argString("key") ?? "?"
    }

    /// Execute assigns the person pinned at propose time (`resolved_assignee_*`,
    /// `internal/tools/jira_write.go`), not whatever the raw `assignee` string
    /// would match now — so the card names that person, plus the words asked
    /// for when they differ and the Jira account id. A row without a pin (none
    /// is ever written without one) falls back to the raw string.
    private static func assignSummaryLines(for action: AgentAction, key: String) -> [String] {
        let asked = action.argString("assignee") ?? "?"
        guard let name = action.argString("resolved_assignee_name"), !name.isEmpty else {
            return ["Issue: \(key) · Assignee: \(asked)"]
        }
        var detail: [String] = []
        if name != asked { detail.append("asked for \"\(asked)\"") }
        if let account = action.argString("resolved_assignee_account_id"), !account.isEmpty {
            detail.append("Jira account \(account)")
        }
        let head = "Issue: \(key) · Assignee: \(name)"
        return detail.isEmpty ? [head] : [head, detail.joined(separator: " · ")]
    }

    /// connect_jira_board + the Reaction Commands Wave 2 tools; nil for a tool
    /// this card has no rendering for (falls back to the raw arguments).
    private static func waveTwoSummaryLines(for action: AgentAction) -> [String]? {
        switch action.tool {
        case "connect_jira_board":
            var lines = ["Project: \(action.argString("project_key") ?? "?")"]
            if let b = action.argString("board_name"), !b.isEmpty { lines.append("Board: \(b)") }
            return lines
        case "create_track":
            return [action.argString("text") ?? action.argsJSON]
        case "create_idea":
            var lines = [action.argString("essence") ?? ""]
            if let t = action.argString("title"), !t.isEmpty { lines.insert(t, at: 0) }
            return lines
        case "remind_me":
            var lines = ["Remind at: \(action.argString("remind_at") ?? "?")"]
            if let n = action.argString("note"), !n.isEmpty { lines.append(n) }
            return lines
        case "brief_context":
            // The applied result is what the tool echoed back for the card
            // (`internal/tools/brief.go`); the args are the proposal.
            return [action.resultString("summary") ?? action.argString("summary") ?? action.argsJSON]
        default:
            return nil
        }
    }

    /// The Slack send this card may edit: only where the host wired
    /// `onApproveEdited` (the main chat and the Inbox strip).
    private var editableSlack: SlackSendProposal? {
        onApproveEdited == nil ? nil : SlackSendProposal(action: action)
    }

    /// The summary, minus the Slack text while the editor shows it.
    private var displayLines: [String] {
        if action.isPending, let slack = editableSlack { return [slack.recipientLine] }
        return Self.summaryLines(for: action)
    }

    private func slackTextBinding(_ slack: SlackSendProposal) -> Binding<String> {
        Binding(get: { slackDraft ?? slack.text }, set: { slackDraft = $0 })
    }

    private var statusLabel: String {
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
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(displayLines, id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
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
            if !action.error.isEmpty {
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
            if action.status == "failed", action.external {
                Text(action.tool == SlackSendProposal.tool ? Self.slackRetryNote() : Self.retryNote(for: action))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let accountID = SlackSendProposal.reconnectAccountID(action), let onReconnectSlack {
                Button("Reconnect Slack") { onReconnectSlack(accountID) }
                    .help("Sign in to Slack again to grant Watchtower permission to send, then Retry")
                    .accessibilityIdentifier("agentAction.reconnectSlack")
            }
            actions
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
        guard let message = gestureError?.message, !message.isEmpty, !action.isTerminal else { return nil }
        if !action.error.isEmpty, message.contains(action.error) || action.error.contains(message) { return nil }
        return message
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: action.external ? "arrow.up.right.square" : "checklist")
                .foregroundStyle(Color.accentColor)
            Text(Self.title(for: action)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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

    @ViewBuilder
    private var actions: some View {
        HStack {
            // A claimed row is being executed by another process: there is
            // nothing the owner can decide about it until it lands.
            if action.isExecuting {
                ProgressView().controlSize(.small)
            } else {
                if action.isPending {
                    if let slack = editableSlack {
                        let text = slackDraft ?? slack.text
                        Button(gestureError?.isApprove == true ? "Retry" : "Approve & send") {
                            if let patch = slack.patch(text: text, pick: slackPick), let onApproveEdited {
                                onApproveEdited(patch)
                            } else {
                                onApprove()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!slack.canApprove(text: text, pick: slackPick))
                    } else if Self.canApprove(action) {
                        Button(gestureError?.isApprove == true ? "Retry" : "Approve", action: onApprove)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Reject", action: onReject)
                } else if action.canRetry {
                    Button("Retry", action: onRetry)
                }
                if inFlight { ProgressView().controlSize(.small) }
            }
        }
        .disabled(inFlight)
    }
}
