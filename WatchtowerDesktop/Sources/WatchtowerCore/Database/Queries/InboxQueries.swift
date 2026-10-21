import Foundation
import GRDB

/// The `inbox_items` table has no screen of its own since the inbox demolition —
/// the detector writes it and Catch-Up reads it. The one lookup left is resolving
/// a recap's `[inbox#id]` ref back to its item (`CatchUpViewModel`).
package enum InboxQueries {

    /// The open Slack, Jira, Linear and mail rows the Messages filter lists
    /// (the Home feed's predicate without its 72-hour window), newest first by
    /// `MAX(created_at, mentioned_at)`; an accumulated channel row is one row.
    /// Snoozed rows are absent until their time.
    package static func fetchOpenMessages(_ db: Database, nowUTC: String, limit: Int = 200) throws -> [HomeFeedInboxRow] {
        let marks = HomeFeedQueries.feedTriggers.map { _ in "?" }.joined(separator: ", ")
        let arguments: [any DatabaseValueConvertible] = HomeFeedQueries.feedTriggers + [nowUTC, limit]
        let rows = try Row.fetchAll(db, sql: """
            SELECT *, MAX(created_at, mentioned_at) AS stamp FROM inbox_items
            WHERE \(openMessage) AND trigger_type IN (\(marks))
              AND (snooze_until = '' OR snooze_until <= ?)
            ORDER BY stamp DESC, id DESC
            LIMIT ?
            """, arguments: StatementArguments(arguments))
        return try rows.map { row in
            let item = InboxItem(row: row)
            let stamp: String = row["stamp"] ?? ""
            return HomeFeedInboxRow(
                item: item,
                stamp: HomeFeedQueries.parse(stamp) ?? Date(timeIntervalSince1970: 0),
                who: try HomeFeedQueries.who(db, item),
                whereText: try HomeFeedQueries.whereText(db, item)
            )
        }
    }

    /// Unread open messages: the Inbox badge's Messages term (same predicate as `fetchOpenMessages`).
    package static func unreadOpenMessageCount(_ db: Database, nowUTC: String) throws -> Int {
        let marks = HomeFeedQueries.feedTriggers.map { _ in "?" }.joined(separator: ", ")
        let arguments: [any DatabaseValueConvertible] = HomeFeedQueries.feedTriggers + [nowUTC]
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM inbox_items
            WHERE \(openMessage) AND trigger_type IN (\(marks))
              AND (snooze_until = '' OR snooze_until <= ?)
              AND (read_at IS NULL OR read_at = '')
            """, arguments: StatementArguments(arguments)) ?? 0
    }

    /// Opening a message card: writes `read_at` only, once.
    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: """
            UPDATE inbox_items SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            WHERE id = ? AND (read_at IS NULL OR read_at = '')
            """, arguments: [id])
    }

    private static let openMessage = "status = 'pending' AND item_class = 'actionable' AND archived_at IS NULL"

    package static func fetchByID(_ db: Database, id: Int) throws -> InboxItem? {
        try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id])
    }
}
