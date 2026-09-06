import Foundation

package enum AgentSurface: String, Sendable {
    case main
    case target
}

/// The system-prompt block that teaches an action surface how write tools
/// work: they create PROPOSALS the owner approves in the chat. Shared by the
/// main AI Chat and the target chat (the two action surfaces, AGENT-04).
package enum AgentToolsContract {
    package static func promptBlock(surface: AgentSurface) -> String {
        let tools: String
        let coexistence: String
        switch surface {
        case .main:
            tools = """
            - create_target — propose a new task or reminder (a task with a due date) in the owner's task list.
            - create_jira_issue — propose a Jira issue on a connected site.
            """
            coexistence = ""
        case .target:
            tools = """
            - create_jira_issue — propose a Jira issue on a connected site.
            """
            coexistence = """

            Changes to THIS task and its vertical line still go through `watchtower-action` blocks \
            (TASK ACTIONS above); a Jira issue goes through the create_jira_issue tool. Never create \
            other Watchtower tasks from here — report the finding in prose instead.
            """
        }
        return """
        === AGENT ACTIONS ===
        You have write TOOLS. A write tool never changes anything by itself: calling it records a \
        PROPOSAL and returns a receipt with an action id. The owner sees a card in this chat and \
        approves or rejects it; only then does the app execute it.
        Write tools on this surface:
        \(tools)
        Rules:
        - After calling a write tool, tell the owner what you proposed and that it awaits their approval; \
        never claim it is done, created, or sent.
        - One proposal per item; never propose the same item twice in one turn.
        - For Jira, call list_jira_projects FIRST to pick a synced project and a known issue type. When the \
        project or type is ambiguous, ask the owner instead of guessing.
        - get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block \
        at the top of the owner's message reports outcomes since your last turn.
        \(coexistence)
        """
    }

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
