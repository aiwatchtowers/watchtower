import Foundation
import GRDB

/// Reads and the one write of `inbox_items` the Desktop does: the Inbox's Messages
/// filter and badge, a message card's `read_at`, and resolving a recap's
/// `[inbox#id]` ref back to its item (`CatchUpViewModel`).
package enum InboxQueries {

    /// The open Slack, Jira, Linear and mail rows the Messages filter lists:
    /// Home's read (`HomeFeedQueries.openMessageRows`) without its 72-hour
    /// window. An accumulated channel row is one row; snoozed rows are absent
    /// until their time.
    package static func fetchOpenMessages(
        _ db: Database, nowUTC: String, limit: Int = openMessageLimit
    ) throws -> [HomeFeedInboxRow] {
        try HomeFeedQueries.openMessageRows(
            db, now: AutomationDates.parse(nowUTC) ?? Date(), since: nil, limit: limit)
    }

    /// How many open messages the Inbox lists, newest first.
    package static let openMessageLimit = 200

    /// Unread open messages: the Inbox badge's Messages term, over the same
    /// rows `fetchOpenMessages` lists (its clause, order and limit), so the
    /// badge never counts a message the list does not show.
    package static func unreadOpenMessageCount(
        _ db: Database, nowUTC: String, limit: Int = openMessageLimit
    ) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (
                SELECT read_at FROM inbox_items
                WHERE \(HomeFeedQueries.openMessageClause)
                ORDER BY MAX(created_at, mentioned_at) DESC, id DESC
                LIMIT ?
            ) WHERE read_at IS NULL OR read_at = ''
            """, arguments: [nowUTC, limit]) ?? 0
    }

    /// Opening a message card: writes `read_at` only, once.
    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: """
            UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            WHERE id = ? AND (read_at IS NULL OR read_at = '')
            """, arguments: [id])
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> InboxItem? {
        try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id])
    }
}
