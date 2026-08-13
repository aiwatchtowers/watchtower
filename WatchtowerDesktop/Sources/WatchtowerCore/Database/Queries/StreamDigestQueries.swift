import Foundation
import GRDB

package enum StreamDigestQueries {
    package static func fetchAll(_ db: Database, limit: Int = 200) throws -> [StreamDigest] {
        try StreamDigest.fetchAll(
            db,
            sql: "SELECT * FROM stream_digests ORDER BY created_at DESC LIMIT ?",
            arguments: [limit]
        )
    }

    package static func markRead(_ db: Database, id: Int) throws {
        try db.execute(
            sql: "UPDATE stream_digests SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ? AND read_at IS NULL",
            arguments: [id]
        )
    }

    package static func unreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_digests WHERE read_at IS NULL") ?? 0
    }
}
