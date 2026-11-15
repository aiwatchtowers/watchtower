import Foundation
import GRDB

/// Reads and the one write of `inbox_items` the Desktop does: the Inbox's Messages
/// list and badge, a message card's `read_at`, and resolving a recap's
/// `[inbox#id]` ref back to its item (`CatchUpViewModel`).
package enum InboxQueries {

    /// The open Slack, Jira, Linear and mail rows the Messages list shows:
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
