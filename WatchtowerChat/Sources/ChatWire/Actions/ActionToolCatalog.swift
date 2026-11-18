import Foundation

/// What an agent-actions tool means to the owner: a human title, one line on
/// what it does, and where its result lands.
public struct ReactionToolInfo: Equatable, Sendable {
    public let title: String
    public let summary: String
    public let destination: String
    /// An `External` or `AlwaysAsk` tool (Go `internal/tools`) — `SetTrust`
    /// refuses `execute` for it, so it lands behind Approve whatever
    /// `tool_trust` says.
    public let alwaysAsks: Bool

    public init(title: String, summary: String, destination: String, alwaysAsks: Bool) {
        self.title = title
        self.summary = summary
        self.destination = destination
        self.alwaysAsks = alwaysAsks
    }
}

/// The ONE tool id → human name mapping: the Inbox cheat sheet, the agent-
/// action card title (on the Mac and the iPhone) and the Settings
/// reaction-dictionary editor all read it, so a tool never goes by two names.
/// An unknown tool id is shown as itself. `WatchtowerCore`'s
/// `ReactionToolCatalog` reads it and adds the reaction wording.
public enum ActionToolCatalog {
    private static let entries: [String: ReactionToolInfo] = [
        "create_target": ReactionToolInfo(
            title: "Create a target",
            summary: "Turns the message into a target",
            destination: "Targets",
            alwaysAsks: false
        ),
        "create_jira_issue": ReactionToolInfo(
            title: "Create a Jira issue",
            summary: "Drafts a Jira issue from the message",
            destination: "Jira",
            alwaysAsks: true
        ),
        // On the reaction surface too (Linear plan 2, lane 3): a mapping may
        // name it to always draft in Linear.
        "create_linear_issue": ReactionToolInfo(
            title: "Create a Linear issue",
            summary: "Drafts a Linear issue",
            destination: "Linear",
            alwaysAsks: true
        ),
        "create_track": ReactionToolInfo(
            title: "Track this",
            summary: "Starts a track following the topic",
            destination: "Tracks",
            alwaysAsks: false
        ),
        "create_idea": ReactionToolInfo(
            title: "Save as idea",
            summary: "Captures the message as an idea",
            destination: "Ideas",
            alwaysAsks: false
        ),
        "remind_me": ReactionToolInfo(
            title: "Remind me",
            summary: "Resurfaces the message later (tomorrow 09:00 unless the message names a time)",
            destination: "Inbox",
            alwaysAsks: false
        ),
        "brief_context": ReactionToolInfo(
            title: "Brief me",
            summary: "Summarises the message's thread: what it's about, who's involved, what's decided, what you're asked",
            destination: "Inbox",
            alwaysAsks: false
        ),
        // Not a reaction tool (main AI Chat only), but its proposals render
        // on the same agent-action card, so it gets its human name here too.
        "connect_jira_board": ReactionToolInfo(
            title: "Connect a Jira board",
            summary: "Starts watching a Jira board",
            destination: "Jira",
            alwaysAsks: true
        ),
        // Main AI Chat only, not a reaction tool. Local, but `AlwaysAsk` in
        // Go: a bulk dismiss always lands behind Approve.
        "dismiss_tracks": ReactionToolInfo(
            title: "Dismiss tracks",
            summary: "Dismisses tracks in bulk (reversible from the Tracks tab)",
            destination: "Tracks",
            alwaysAsks: true
        ),
        // Chat-only Jira issue writes (spec 2026-09-26 §8) — External, so they
        // always land behind Approve; not in ReactionDictionaryTools.all.
        "add_jira_comment": ReactionToolInfo(
            title: "Comment on a Jira issue",
            summary: "Posts a comment on an existing issue",
            destination: "Jira",
            alwaysAsks: true
        ),
        "transition_jira_issue": ReactionToolInfo(
            title: "Move a Jira issue",
            summary: "Moves an existing issue to another status",
            destination: "Jira",
            alwaysAsks: true
        ),
        "assign_jira_issue": ReactionToolInfo(
            title: "Assign a Jira issue",
            summary: "Sets an existing issue's assignee",
            destination: "Jira",
            alwaysAsks: true
        ),
        "update_jira_issue": ReactionToolInfo(
            title: "Update a Jira issue",
            summary: "Edits an existing issue's summary, priority, labels or due date",
            destination: "Jira",
            alwaysAsks: true
        ),
        // The Linear twins of the Jira writes (#694) — External, so always
        // behind Approve; for approval-card titles, not the reaction dictionary.
        "add_linear_comment": ReactionToolInfo(
            title: "Comment on a Linear issue",
            summary: "Posts a comment on an existing issue",
            destination: "Linear",
            alwaysAsks: true
        ),
        "transition_linear_issue": ReactionToolInfo(
            title: "Move a Linear issue",
            summary: "Moves an existing issue to another workflow state",
            destination: "Linear",
            alwaysAsks: true
        ),
        "assign_linear_issue": ReactionToolInfo(
            title: "Assign a Linear issue",
            summary: "Sets an existing issue's assignee",
            destination: "Linear",
            alwaysAsks: true
        ),
        "update_linear_issue": ReactionToolInfo(
            title: "Update a Linear issue",
            summary: "Edits an existing issue's title, priority, labels, due date or estimate",
            destination: "Linear",
            alwaysAsks: true
        ),
        // Chat-only Confluence page edit (spec 2026-09-30 §6) — External.
        "edit_confluence_page": ReactionToolInfo(
            title: "Edit a Confluence page",
            summary: "Changes text or a section of an existing Confluence page",
            destination: "Confluence",
            alwaysAsks: true
        ),
        // Main chat + workbench sessions (spec 2026-10-02) — External: always
        // behind Approve, the owner may edit the text first.
        "send_slack_message": ReactionToolInfo(
            title: "Send to Slack",
            summary: "Sends a message as you to a channel, a thread or a person",
            destination: "Slack",
            alwaysAsks: true
        ),
        // Main chat only (spec 2026-10-16 D5) — External, AlwaysAsk, applied
        // by the chat session itself once approved.
        ConnectorCallProposal.tool: ReactionToolInfo(
            title: "Use a claude.ai connector",
            summary: "Runs a write through one of your claude.ai connectors once you approve it",
            destination: "claude.ai",
            alwaysAsks: true
        )
    ]

    public static func info(for tool: String) -> ReactionToolInfo? {
        entries[tool]
    }

    public static func title(for tool: String) -> String {
        entries[tool]?.title ?? tool
    }
}
