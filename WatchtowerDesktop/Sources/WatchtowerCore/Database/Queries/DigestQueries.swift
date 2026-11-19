import Foundation
import GRDB

package enum DigestQueries {
    package static func fetchAll(
        _ db: Database,
        type: String? = nil,
        channelID: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [Digest] {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let type {
            conditions.append("type = ?")
            args.append(type)
        }
        if let channelID {
            conditions.append("channel_id = ?")
            args.append(channelID)
        }

        var sql = "SELECT * FROM digests"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        args.append(limit)
        args.append(offset)

        return try Digest.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> Digest? {
        try Digest.fetchOne(db, sql: "SELECT * FROM digests WHERE id = ?", arguments: [id])
    }

    package static func fetchLatest(_ db: Database, type: String) throws -> Digest? {
        try Digest.fetchOne(
            db,
            sql: """
                SELECT * FROM digests WHERE type = ?
                ORDER BY created_at DESC LIMIT 1
                """,
            arguments: [type]
        )
    }

    package static func fetchWithDecisions(_ db: Database, limit: Int = 50, offset: Int = 0) throws -> [Digest] {
        try Digest.fetchAll(
            db,
            sql: """
                SELECT * FROM digests
                WHERE decisions != '[]' AND decisions IS NOT NULL
                ORDER BY created_at DESC LIMIT ? OFFSET ?
                """,
            arguments: [limit, offset]
        )
    }

    // MARK: - Read tracking

    package static func unreadDigestCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests WHERE read_at IS NULL") ?? 0
    }

    // MARK: - Digest Topics

    package static func fetchTopics(_ db: Database, digestID: Int) throws -> [DigestTopic] {
        guard try db.tableExists("digest_topics") else { return [] }
        return try DigestTopic.fetchAll(
            db,
            sql: "SELECT * FROM digest_topics WHERE digest_id = ? ORDER BY idx",
            arguments: [digestID]
        )
    }

    package static func fetchTopicsByDigestIDs(_ db: Database, digestIDs: [Int]) throws -> [DigestTopic] {
        guard !digestIDs.isEmpty, try db.tableExists("digest_topics") else { return [] }
        let placeholders = digestIDs.map { _ in "?" }.joined(separator: ",")
        return try DigestTopic.fetchAll(
            db,
            sql: "SELECT * FROM digest_topics WHERE digest_id IN (\(placeholders)) ORDER BY digest_id, idx",
            arguments: StatementArguments(digestIDs)
        )
    }
}
