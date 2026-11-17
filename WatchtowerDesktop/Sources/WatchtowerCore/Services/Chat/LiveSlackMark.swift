import Foundation
import GRDB

/// LIVE-01: a conversation that used the Live Slack connector is marked
/// (`chat_conversations.live_slack_since` = the chat_messages.id of the first
/// turn that did), and that turn and every later one stay out of every store
/// that makes chat text lasting. Swift is the only writer of chat rows, so the
/// mark is written here, in the turn's finalizing transaction.
///
/// Assumption: only the main chat surface gets Slack connectors (the claude.ai
/// tools and Codex apps are main-surface only), so embedded chats never carry
/// a Slack step and need no mark of their own.
///
/// The mark is written when a Slack step starts (a Live turn's partial text is
/// saved while it runs, and a crash never finalizes) and again at finalize as
/// a backstop; whichever comes first wins.
package enum LiveSlackMark {
    /// Step names as Go's chat events carry them (`displayToolName`, the
    /// name `chat_turn_steps.name` stores), pinned by Go's
    /// `internal/slacklive/testdata/slack_step_names.json`
    /// (`TestLIVE01_StepNamesFixture`), which `LiveSlack01GuardTests` reads.
    /// Claude's claude.ai Slack connector: `claude_ai_Slack:<tool>`, read and
    /// write tools alike (Go's `slackconnector.ClaudeStepPrefix`).
    static let claudePrefix = "claude_ai_Slack:"
    /// Codex's Slack app, an `mcp_tool_call` of server `codex_apps` with tool
    /// `slack.<tool>`: `codex_apps:slack.<tool>` (Go's
    /// `slackconnector.CodexStepPrefix`). Every tool of it marks, so a tool the
    /// allow-list should have hidden still keeps the turn out of lasting stores.
    static let codexPrefix = "codex_apps:slack."

    package static func isSlackConnectorStep(_ name: String) -> Bool {
        name.hasPrefix(claudePrefix) || name.hasPrefix(codexPrefix)
    }

    package static func isMarked(_ db: Database, conversationID: Int64) throws -> Bool {
        try Int64.fetchOne(db, sql: "SELECT live_slack_since FROM chat_conversations WHERE id = ?",
                           arguments: [conversationID]) != nil
    }
}
