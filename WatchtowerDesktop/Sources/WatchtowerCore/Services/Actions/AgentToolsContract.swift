import Foundation

package enum AgentSurface: String, Sendable {
    case main
    case target
}

/// The system-prompt block that teaches an action surface how write tools
/// work: they create PROPOSALS the owner approves in the chat, unless the
/// owner pre-approved the tool. Shared by the main AI Chat and the target
/// chat (the two action surfaces, AGENT-04).
package enum AgentToolsContract {
    /// Byte-identical to Go `chat.ActionsContract` (`internal/chat/actions_contract.go`),
    /// pinned on both sides by `internal/chat/testdata/actions_contract_{main,target}.txt`.
    /// Change both copies and the fixture together.
    package static func promptBlock(surface: AgentSurface) -> String {
        let tools: [String]
        switch surface {
        case .main: tools = mainTools
        case .target: tools = targetTools
        }
        let surfaceRules = surface == .main
            ? Array(rules.dropLast()) + [slackSendRule] + [rules[rules.count - 1]]
            : rules
        var text = (header + tools + surfaceRules).joined(separator: "\n")
        if surface == .target {
            text += "\n\n" + targetCoexistence
        }
        return text
    }

    private static let header = [
        "=== AGENT ACTIONS ===",
        "You have write TOOLS. A write tool never changes anything by itself: calling it records a PROPOSAL and "
            + "returns a receipt with an action id and a status. The owner sees a card in this chat and approves or "
            + "rejects it; only then does the app execute it. A tool the owner has pre-approved runs at once, and its "
            + "receipt already says \"applied\".",
        "Write tools on this surface:"
    ]

    private static let jiraIssueWriteTools = [
        "- add_jira_comment — propose a comment on an existing Jira issue.",
        "- transition_jira_issue — propose moving a Jira issue to another status; pass the target status name.",
        "- assign_jira_issue — propose assigning a Jira issue to \"me\" (the owner), an email, or a display name.",
        "- update_jira_issue — propose changing a Jira issue's summary, priority, labels, or due date."
    ]

    private static let confluenceWriteTools = [
        "- edit_confluence_page — propose edits to a Confluence page: replace_text for a passage, replace_section to "
            + "rewrite a section; the owner approves a word-level diff before anything is written."
    ]

    private static let mainTools = [
        "- create_target — propose a new task or reminder (a task with a due date) in the owner's task list.",
        "- create_jira_issue — propose a Jira issue on a connected site.",
        "- connect_jira_board — propose watching a Jira board so its issues start syncing; pass board_name when "
            + "the project has several boards, and ask the owner when the project is ambiguous."
    ] + jiraIssueWriteTools + confluenceWriteTools + [
        "- create_track — propose a track that follows a topic over time.",
        "- create_idea — capture an idea in the owner's ideas registry.",
        "- remind_me — set a reminder that resurfaces in the Inbox at a chosen time; pass message_ref when it is "
            + "about one Slack message.",
        "- send_slack_message — propose a Slack message sent as the owner to a channel, a thread (pass a message "
            + "link), or a person (DM)."
    ]

    /// The main surface's Slack send rule, placed before the closing get_action line.
    private static let slackSendRule = "- To write to Slack, call get_writing_style FIRST and draft the message in "
        + "the owner's own voice: their language, their tone for this audience, short, no facts you were not given. "
        + "Mention people as <@USER_ID>. The owner sees the text on the card and may edit it before approving."

    private static let targetTools = ["- create_jira_issue — propose a Jira issue on a connected site."]
        + jiraIssueWriteTools + confluenceWriteTools

    private static let rules = [
        "Rules:",
        "- Read the receipt. Status \"pending\": tell the owner what you proposed and that it awaits their approval; "
            + "never claim it is done, created, or sent. Status \"applied\": report what was done.",
        "- One proposal per item; never propose the same item twice in one turn.",
        "- For a new Jira issue, call list_jira_projects FIRST to pick a synced project and a known issue type. "
            + "When the project or type is ambiguous, ask the owner instead of guessing.",
        "- For an existing Jira issue, pass its key (e.g. ABC-123); call get_jira_issue first when you are not sure "
            + "of its current status, assignee, or fields.",
        "- To edit a Confluence page, read it with get_confluence_page first (a live read with every comment) and "
            + "pass its version as base_version. Prefer replace_text for a small edit. Keep every ⟦…⟧ marker you do not "
            + "mean to delete, verbatim. After a \"page changed\" error, read the page again and propose again.",
        "- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block at the "
            + "top of the owner's message reports outcomes since your last turn."
    ]

    private static let targetCoexistence = "Changes to THIS task and its vertical line still go through "
        + "`watchtower-action` blocks (TASK ACTIONS above); Jira work goes through the Jira tools. Never create "
        + "other Watchtower tasks from here — report the finding in prose instead."

    /// The honest variant for a provider without tools (Ollama): the TOOLS
    /// section is replaced, nothing promises what the session cannot do.
    package static let noToolsBlock = """
        === TOOLS ===
        No tools are connected in this session. Answer from the conversation only, and say so plainly \
        when the owner asks you to look something up or to create something.
        """

    /// Outcomes to prepend to the owner's next message, nil when there are
    /// none — the target chat's context re-injection precedent. Not persisted.
    package static func actionsSinceLastTurnBlock(_ rows: [AgentAction]) -> String? {
        guard !rows.isEmpty else { return nil }
        let lines = rows.map { row -> String in
            var line = "- #\(row.id) \(row.tool): \(row.status)"
            if row.status == "applied", !row.resultJSON.isEmpty {
                line += " — \(row.resultJSON)"
            } else if !row.error.isEmpty {
                line += " — \(row.error)"
            }
            return line
        }
        return "=== ACTIONS SINCE YOUR LAST MESSAGE ===\n" + lines.joined(separator: "\n")
    }
}
