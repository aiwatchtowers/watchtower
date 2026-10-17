import GRDB

package enum MessageQueries {
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

    package static func countByChannel(_ db: Database, channelID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE channel_id = ?", arguments: [channelID]) ?? 0
    }
}
