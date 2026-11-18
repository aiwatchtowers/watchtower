import Foundation

/// The approval card's text lines for a proposal's args, per tool — the same
/// words on the Mac and the iPhone. A tool with no rendering here falls back
/// to the raw arguments.
public enum ActionSummaryLines {
    public static func summaryLines(for action: ChatAgentAction) -> [String] {
        // Clipped args cannot be read: the tool's "too long" line, or the clipped text itself.
        if action.argsClipped { return [clippedLine(for: action.tool) ?? action.argsJSON] }
        switch action.tool {
        case "create_target":
            var lines = [action.argString("text") ?? ""]
            var meta: [String] = []
            if let due = action.argString("due"), !due.isEmpty { meta.append("Due: \(due)") }
            if let p = action.argString("priority"), !p.isEmpty { meta.append("Priority: \(p)") }
            // An Inbox card's target button may name a parent task (Inbox builder A).
            if let parent = action.argString("parent_id"), !parent.isEmpty { meta.append("Under task #\(parent)") }
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
                ?? jiraIssueWriteSummaryLines(for: action) ?? linearSummaryLines(for: action)
                ?? slackSummaryLines(for: action) ?? [action.argsJSON]
        }
    }

    /// The line for a proposal whose args reached this device clipped (`ChatAgentAction.argsClipped`): too long to
    /// show in full here, which is not unreadable. Nil for a tool with no such line (its clipped text is shown).
    public static func clippedLine(for tool: String) -> String? {
        switch tool {
        case SlackSendProposal.tool: SlackSendProposal.clippedNote
        case ConnectorCallProposal.tool: ConnectorCallProposal.clippedNote
        case ConfluenceEdit.tool: ConfluenceEdit.clippedNote
        default: nil
        }
    }

    /// The `send_slack_message` text-only summary (cheat sheet, tests); the
    /// card itself shows the recipient with `SlackRecipientLine`. Nil for any
    /// other tool or unreadable args.
    public static func slackSummaryLines(for action: ChatAgentAction) -> [String]? {
        guard let proposal = SlackSendProposal(action: action) else { return nil }
        return [proposal.recipientLine, proposal.text]
    }

    /// The `edit_confluence_page` line; nil for any other tool.
    public static func confluenceEditSummaryLines(for action: ChatAgentAction) -> [String]? {
        guard action.tool == ConfluenceEdit.tool else { return nil }
        if action.argsClipped { return [ConfluenceEdit.clippedNote] }
        guard let edit = ConfluenceEdit.proposal(for: action) else { return ["Unreadable Confluence edit proposal"] }
        return ["Page: \(edit.title) · edits version \(edit.baseVersion)"]
    }

    /// The four existing-issue Jira writes (spec 2026-09-26 §8); nil for any
    /// other tool — decided on the tool name alone, before any args decode.
    private static func jiraIssueWriteSummaryLines(for action: ChatAgentAction) -> [String]? {
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

    /// The Linear writes: only the owner-facing fields, never the pinned ids
    /// (`team_id`, `label_ids`, `issue_uuid`, …). Nil for any other tool.
    private static func linearSummaryLines(for action: ChatAgentAction) -> [String]? {
        func present(_ pairs: [(String, String)]) -> [String] {
            pairs.compactMap { arg, title in
                action.argString(arg).flatMap { $0.isEmpty ? nil : "\(title): \($0)" }
            }
        }
        func first(_ keys: [String]) -> String? {
            keys.lazy.compactMap { action.argString($0) }.first { !$0.isEmpty }
        }
        switch action.tool {
        case "create_linear_issue":
            return present([("team", "Team"), ("title", "Title"), ("description", "Description"), ("state", "State"),
                            ("assignee", "Assignee"), ("labels", "Labels"), ("priority", "Priority")])
        case "add_linear_comment":
            return ["Issue: \(issueKey(action))", action.argString("body") ?? ""]
        case "transition_linear_issue":
            return ["Issue: \(issueKey(action)) → \(first(["state_name", "state", "state_type"]) ?? "?")"]
        case "assign_linear_issue":
            return ["Issue: \(issueKey(action)) · Assignee: \(first(["assignee_name", "assignee"]) ?? "?")"]
        case "update_linear_issue":
            return ["Issue: \(issueKey(action))"] + present([
                ("title", "Title"), ("priority", "Priority"), ("labels_add", "Add labels"),
                ("labels_remove", "Remove labels"), ("due_date", "Due"), ("estimate", "Estimate")])
        default:
            return nil
        }
    }

    private static func issueKey(_ action: ChatAgentAction) -> String {
        action.argString("key") ?? "?"
    }

    /// Execute assigns the person pinned at propose time (`resolved_assignee_*`,
    /// `internal/tools/jira_write.go`), not whatever the raw `assignee` string
    /// would match now — so the card names that person, plus the words asked
    /// for when they differ and the Jira account id. A row without a pin (none
    /// is ever written without one) falls back to the raw string.
    private static func assignSummaryLines(for action: ChatAgentAction, key: String) -> [String] {
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
    private static func waveTwoSummaryLines(for action: ChatAgentAction) -> [String]? {
        switch action.tool {
        case "connect_jira_board":
            var lines = ["Project: \(action.argString("project_key") ?? "?")"]
            if let b = action.argString("board_name"), !b.isEmpty { lines.append("Board: \(b)") }
            return lines
        case "create_track":
            return [action.argString("text") ?? action.argsJSON]
        case "dismiss_tracks":
            return dismissTracksSummaryLines(for: action)
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

    /// dismiss_tracks: the summary line and sample titles Go pinned at
    /// propose time (`internal/tools/tracks.go` normalizeDismissTracks), plus
    /// how many tracks the preview leaves out. One args decode.
    private static func dismissTracksSummaryLines(for action: ChatAgentAction) -> [String] {
        let args = action.args
        let titles = (args["sample_titles"] as? [Any])?.compactMap { ChatAgentAction.stringValue($0) } ?? []
        let total = (args["resolved_ids"] as? [Any])?.count ?? titles.count
        var lines = [ChatAgentAction.stringValue(args["summary"]) ?? "Dismiss tracks"]
        lines += titles.map { "• \($0)" }
        if total > titles.count { lines.append("…and \(total - titles.count) more") }
        return lines
    }
}
