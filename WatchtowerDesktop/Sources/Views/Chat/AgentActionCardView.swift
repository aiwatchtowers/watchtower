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

    static func title(for action: AgentAction) -> String {
        switch action.tool {
        case "create_target": return "Create task"
        case "create_jira_issue": return "Create Jira issue"
        case "connect_jira_board": return "Connect Jira board"
        case "create_track": return "Create track"
        case "create_idea": return "Capture idea"
        case "remind_me": return "Remind me"
        case "brief_context": return "Brief context"
        default: return action.tool
        }
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
            return waveTwoSummaryLines(for: action) ?? [action.argsJSON]
        }
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
            return [action.argString("title") ?? action.argString("text") ?? action.argsJSON]
        case "create_idea":
            var lines = [action.argString("essence") ?? ""]
            if let t = action.argString("title"), !t.isEmpty { lines.insert(t, at: 0) }
            return lines
        case "remind_me":
            var lines = ["Remind at: \(action.argString("remind_at") ?? "?")"]
            if let n = action.argString("note"), !n.isEmpty { lines.append(n) }
            return lines
        case "brief_context":
            return [action.argString("summary") ?? action.argsJSON]
        default:
            return nil
        }
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
            ForEach(Self.summaryLines(for: action), id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !action.reason.isEmpty {
                Text(action.reason).font(.caption).foregroundStyle(.secondary).italic()
            }
            outcome
            if !action.error.isEmpty {
                Text(action.error).font(.caption).foregroundStyle(.red)
            }
            // Only a FAILED row can have left a half-finished external write:
            // Apply claims the row before it runs the tool, so an `approved`
            // one provably never reached Jira.
            if action.status == "failed", action.external {
                Text("Retrying re-sends the request — check Jira for a duplicate first.")
                    .font(.caption).foregroundStyle(.orange)
            }
            actions
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
        if action.status == "applied", let url = action.resultString("url"), let key = action.resultString("key"),
           let link = URL(string: url) {
            Link(key, destination: link).font(.callout)
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

    @ViewBuilder
    private var actions: some View {
        HStack {
            // A claimed row is being executed by another process: there is
            // nothing the owner can decide about it until it lands.
            if action.isExecuting {
                ProgressView().controlSize(.small)
            } else {
                if action.isPending {
                    Button("Approve", action: onApprove).buttonStyle(.borderedProminent)
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
