import GRDB
import WatchtowerCore

package enum MessageQueries {
    package static func fetchByChannel(_ db: Database, channelID: String, limit: Int = 50, offset: Int = 0) throws -> [Message] {
        // Load the latest messages by using a subquery with DESC, then re-order ASC for display
        try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM (
                    SELECT * FROM messages
                    WHERE channel_id = ?
                    ORDER BY ts_unix DESC
                    LIMIT ? OFFSET ?
                ) ORDER BY ts_unix ASC
                """,
            arguments: [channelID, limit, offset]
        )
    }

    package static func fetchByTimeRange(_ db: Database, channelID: String, from: Double, to: Double) throws -> [Message] {
        try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM messages
                WHERE channel_id = ? AND ts_unix >= ? AND ts_unix <= ?
                ORDER BY ts_unix ASC
                """,
            arguments: [channelID, from, to]
        )
    }

    package static func fetchThreadReplies(_ db: Database, channelID: String, threadTS: String) throws -> [Message] {
        try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM messages
                WHERE channel_id = ? AND thread_ts = ?
                ORDER BY ts_unix ASC
                """,
            arguments: [channelID, threadTS]
        )
    }

    package static func fetchRecentWatched(_ db: Database, sinceUnix: Double, limit: Int = 50) throws -> [MessageWithContext] {
        try MessageWithContext.fetchAll(
            db,
            sql: """
                SELECT m.*, c.name as channel_name, u.display_name as user_name
                FROM messages m
                JOIN channels c ON c.id = m.channel_id
                LEFT JOIN users u ON u.id = m.user_id
                JOIN watch_list w ON w.entity_type = 'channel' AND w.entity_id = m.channel_id
                WHERE m.ts_unix > ?
                ORDER BY m.ts_unix DESC
                LIMIT ?
                """,
            arguments: [sinceUnix, limit]
        )
    }

    package static func countByChannel(_ db: Database, channelID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE channel_id = ?", arguments: [channelID]) ?? 0
    }

    /// Full thread (root + replies) in chronological order. Mirrors Go's GetThreadContext but unbounded
    /// up to `limit` so the UI shows the full conversation, not just the AI-prompt slice.
    package static func fetchInboxThread(_ db: Database, channelID: String, threadTS: String, limit: Int = 200) throws -> [Message] {
        try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM messages
                WHERE channel_id = ? AND (thread_ts = ? OR ts = ?) AND is_deleted = 0
                ORDER BY ts_unix ASC
                LIMIT ?
                """,
            arguments: [channelID, threadTS, threadTS, limit]
        )
    }

    /// Window of top-level (non-threaded) channel messages around a trigger ts: `before` messages
    /// strictly before, the trigger itself, and `after` messages strictly after — chronological.
    package static func fetchInboxChannelWindow(
        _ db: Database, channelID: String, aroundTS: String, before: Int = 10, after: Int = 10
    ) throws -> [Message] {
        let earlier = try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM messages
                WHERE channel_id = ? AND ts < ?
                  AND (thread_ts IS NULL OR thread_ts = '' OR thread_ts = ts)
                  AND is_deleted = 0
                ORDER BY ts_unix DESC
                LIMIT ?
                """,
            arguments: [channelID, aroundTS, before]
        ).reversed()

        let triggerAndAfter = try Message.fetchAll(
            db,
            sql: """
                SELECT * FROM messages
                WHERE channel_id = ? AND ts >= ?
                  AND (thread_ts IS NULL OR thread_ts = '' OR thread_ts = ts)
                  AND is_deleted = 0
                ORDER BY ts_unix ASC
                LIMIT ?
                """,
            arguments: [channelID, aroundTS, after + 1]
        )

        return Array(earlier) + triggerAndAfter
    }
}

package struct MessageWithContext: FetchableRecord, Decodable, Identifiable, Equatable {
    package let channelID: String
    package let ts: String
    package let userID: String
    package let text: String
    package let threadTS: String?
    package let replyCount: Int
    package let isEdited: Bool
    package let isDeleted: Bool
    package let subtype: String
    package let permalink: String
    package let tsUnix: Double
    package let rawJSON: String
    package let channelName: String?
    package let userName: String?

    package var id: String { "\(channelID)_\(ts)" }

    package enum CodingKeys: String, CodingKey {
        case ts, text, subtype, permalink
        case channelID = "channel_id"
        case userID = "user_id"
        case threadTS = "thread_ts"
        case replyCount = "reply_count"
        case isEdited = "is_edited"
        case isDeleted = "is_deleted"
        case tsUnix = "ts_unix"
        case rawJSON = "raw_json"
        case channelName = "channel_name"
        case userName = "user_name"
    }
}
