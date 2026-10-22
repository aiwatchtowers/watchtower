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
    package static func fetchOpenMessages(_ db: Database, nowUTC: String, limit: Int = 200) throws -> [HomeFeedInboxRow] {
        try HomeFeedQueries.openMessageRows(
            db, now: AutomationDates.parse(nowUTC) ?? Date(), since: nil, limit: limit)
    }

    /// Unread open messages: the Inbox badge's Messages term (same clause as `fetchOpenMessages`).
    package static func unreadOpenMessageCount(_ db: Database, nowUTC: String) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM inbox_items
            WHERE \(HomeFeedQueries.openMessageClause) AND (read_at IS NULL OR read_at = '')
            """, arguments: [nowUTC]) ?? 0
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
