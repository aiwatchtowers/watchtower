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
    /// Claude's claude.ai Slack connector tools.
    static let claudePrefix = "mcp__claude_ai_Slack__"
    /// Codex's Slack app: the shared `codex_apps` server with tool `slack.<tool>`
    /// (the name the Codex stream translation stores; read and write tools alike).
    static let codexPrefix = "mcp__codex_apps__slack."

    package static func isSlackConnectorStep(_ name: String) -> Bool {
        name.hasPrefix(claudePrefix) || name.hasPrefix(codexPrefix)
    }

    /// Marks the conversation of `messageID` when a step with this name starts.
    package static func markIfSlackStep(_ db: Database, messageID: Int64, name: String) throws {
        guard isSlackConnectorStep(name) else { return }
        try db.execute(sql: """
            UPDATE chat_conversations SET live_slack_since = ?
            WHERE id = (SELECT conversation_id FROM chat_messages WHERE id = ?) AND live_slack_since IS NULL
            """, arguments: [messageID, messageID])
    }

    /// Marks the conversation when the turn's steps include a Slack connector
    /// call; an already marked conversation keeps its first mark.
    package static func markIfUsed(_ db: Database, conversationID: Int64, messageID: Int64) throws {
        let names = try String.fetchAll(db, sql: "SELECT name FROM chat_turn_steps WHERE message_id = ?", arguments: [messageID])
        guard names.contains(where: isSlackConnectorStep) else { return }
        try db.execute(sql: """
            UPDATE chat_conversations SET live_slack_since = ? WHERE id = ? AND live_slack_since IS NULL
            """, arguments: [messageID, conversationID])
    }

    package static func isMarked(_ db: Database, conversationID: Int64) throws -> Bool {
        try Int64.fetchOne(db, sql: "SELECT live_slack_since FROM chat_conversations WHERE id = ?",
                           arguments: [conversationID]) != nil
    }
}
