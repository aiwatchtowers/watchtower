import Foundation
import GRDB

enum IdeaQueries {

    // MARK: - Fetch

    /// Ideas filtered by kind/status and a free-text query, most-recently-updated first.
    /// The query matches an idea's title/essence or any of its mentions' quotes.
    static func fetchList(
        _ db: Database,
        kind: String?,
        status: String?,
        query: String?,
        limit: Int
    ) throws -> [Idea] {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let kind {
            conditions.append("kind = ?")
            args.append(kind)
        }

        if let status {
            conditions.append("status = ?")
            args.append(status)
        }

        if let query, !query.isEmpty {
            conditions.append("""
                (title LIKE ? OR essence LIKE ? OR id IN (
                    SELECT idea_id FROM idea_mentions WHERE quote LIKE ?
                ))
                """)
            let pattern = "%\(query)%"
            args.append(pattern)
            args.append(pattern)
            args.append(pattern)
        }

        var sql = "SELECT * FROM ideas"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"
        args.append(limit)

        return try Idea.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Ideas awaiting owner review: freshly proposed, or explicitly flagged.
    static func fetchForReview(_ db: Database) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas
            WHERE status = 'proposed' OR needs_review = 1
            ORDER BY updated_at DESC
            """)
    }

    static func fetchOne(_ db: Database, id: Int) throws -> Idea? {
        try Idea.fetchOne(db, sql: "SELECT * FROM ideas WHERE id = ?", arguments: [id])
    }

    /// An idea's mentions, oldest first.
    static func fetchMentions(_ db: Database, ideaID: Int) throws -> [IdeaMention] {
        try IdeaMention.fetchAll(db, sql: """
            SELECT * FROM idea_mentions WHERE idea_id = ? ORDER BY created_at ASC
            """, arguments: [ideaID])
    }

    static func countForReview(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ideas WHERE status = 'proposed' OR needs_review = 1
            """) ?? 0
    }

    // MARK: - Status Updates

    /// Sets the idea's status directly (e.g. active/rejected/dropped), clearing
    /// any pending review flag since the owner just acted on it.
    static func setStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = ?, needs_review = 0, review_reason = '',
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [status, id]
        )
    }

    static func snooze(_ db: Database, id: Int, until: String?) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'not_now', snooze_until = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [until ?? "", id]
        )
    }

    /// Merges an idea into another: re-parents its mentions onto the target,
    /// then marks it merged with a link back to the target.
    static func merge(_ db: Database, id: Int, into targetID: Int) throws {
        try db.execute(
            sql: "UPDATE idea_mentions SET idea_id = ? WHERE idea_id = ?",
            arguments: [targetID, id]
        )
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'merged', merged_into_id = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [targetID, id]
        )
    }

    /// Marks an idea superseded, optionally linking to the idea that replaces it.
    static func supersede(_ db: Database, id: Int, by newID: Int?) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'superseded', superseded_by_id = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [newID, id]
        )
    }

    static func setRating(_ db: Database, id: Int, rating: Int, comment: String) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET owner_rating = ?, rating_comment = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [rating, comment, id]
        )
    }

    /// Creates an owner-authored idea directly, active and free of review, with
    /// an 'owner' mention carrying the essence text.
    @discardableResult
    static func createManual(_ db: Database, kind: String, title: String, essence: String) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO ideas (kind, title, essence, status, source)
                VALUES (?, ?, ?, 'active', 'owner')
                """,
            arguments: [kind, title, essence]
        )
        let ideaID = db.lastInsertedRowID
        try db.execute(
            sql: """
                INSERT INTO idea_mentions (idea_id, source, quote)
                VALUES (?, 'owner', ?)
                """,
            arguments: [ideaID, essence]
        )
        return ideaID
    }

    /// Marks an idea converted into a Target, recording the link.
    static func markConverted(_ db: Database, id: Int, targetID: Int64) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'converted', converted_target_id = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [targetID, id]
        )
    }
}
