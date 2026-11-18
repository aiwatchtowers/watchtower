import Foundation
import GRDB

/// LIVE-01: a conversation that used the Live Slack connector is marked
/// (`chat_conversations.live_slack_since` = the chat_messages.id of the first
/// turn that did), and that turn and every later one stay out of every store
/// that makes chat text lasting. The mark is the engine's to write (Go
/// `internal/chatstore`, when a Slack step starts and again at finalize; the
/// app writes no main-chat row since the unified chat, D3); the app only reads
/// it, for the artifact panel's Keep.
package enum LiveSlackMark {
    package static func isMarked(_ db: Database, conversationID: Int64) throws -> Bool {
        try Int64.fetchOne(db, sql: "SELECT live_slack_since FROM chat_conversations WHERE id = ?",
                           arguments: [conversationID]) != nil
    }
}
