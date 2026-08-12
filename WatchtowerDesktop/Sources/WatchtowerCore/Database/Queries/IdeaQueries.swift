import Foundation
import GRDB
import WatchtowerCore

package enum IdeaQueries {

    // MARK: - Fetch

    /// Ideas filtered by kind/status and a free-text query, most-recently-updated first.
    /// The query matches an idea's title/essence or any of its mentions' quotes.
    ///
    /// `excludingReviewQueue` drops what `fetchForReview` already returns —
    /// mirroring `Idea.isForReview` in SQL. Filtering those out in Swift after
    /// the fact silently shrinks the page: with the limit spent on review items
    /// the registry list comes back short, and worse as the queue grows.
    package static func fetchList(
        _ db: Database,
        kind: String?,
        status: String?,
        query: String?,
        limit: Int,
        excludingReviewQueue: Bool = false
    ) throws -> [Idea] {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if excludingReviewQueue {
            conditions.append("NOT (status = 'proposed' OR needs_review = 1)")
        }

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
    package static func fetchForReview(_ db: Database) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas
            WHERE status = 'proposed' OR needs_review = 1
            ORDER BY updated_at DESC
            """)
    }

    package static func fetchOne(_ db: Database, id: Int) throws -> Idea? {
        try Idea.fetchOne(db, sql: "SELECT * FROM ideas WHERE id = ?", arguments: [id])
    }

    /// An idea's mentions, oldest first. Ordered by `said_at, id` to match the
    /// Go reader (`db.ListIdeaMentions`) exactly — a dual path, so the two
    /// sides must agree. `created_at` is when the row was WRITTEN, which for a
    /// batch the consolidator wrote in one transaction is the same value for
    /// every mention, leaving the chronology in insert order rather than the
    /// order things were actually said.
    package static func fetchMentions(_ db: Database, ideaID: Int) throws -> [IdeaMention] {
        try IdeaMention.fetchAll(db, sql: """
            SELECT * FROM idea_mentions WHERE idea_id = ? ORDER BY said_at, id
            """, arguments: [ideaID])
    }

    package static func countForReview(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ideas WHERE status = 'proposed' OR needs_review = 1
            """) ?? 0
    }

    // MARK: - Status Updates

    /// Sets the idea's status directly (e.g. active/rejected/dropped), clearing
    /// any pending review flag since the owner just acted on it.
    package static func setStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = ?, \(clearReviewFlag),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [status, id]
        )
    }

    /// Every owner action clears the pending review flag, `setStatus` included:
    /// `needs_review` means "the owner has not looked at this since it
    /// resurfaced", and each of these IS the owner looking at it. An action
    /// that left the flag set would leave the idea stuck in the "For review"
    /// list with no reachable way out (IDEA-04).
    private static let clearReviewFlag = "needs_review = 0, review_reason = ''"

    package static func snooze(_ db: Database, id: Int, until: String?) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'not_now', snooze_until = ?, \(clearReviewFlag),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [until ?? "", id]
        )
    }

    /// Merges an idea into another: re-parents its mentions onto the target,
    /// then marks it merged with a link back to the target.
    package static func merge(_ db: Database, id: Int, into targetID: Int) throws {
        try db.execute(
            sql: "UPDATE idea_mentions SET idea_id = ? WHERE idea_id = ?",
            arguments: [targetID, id]
        )
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'merged', merged_into_id = ?, \(clearReviewFlag),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [targetID, id]
        )
    }

    /// Marks an idea superseded, optionally linking to the idea that replaces it.
    package static func supersede(_ db: Database, id: Int, by newID: Int?) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'superseded', superseded_by_id = ?, \(clearReviewFlag),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [newID, id]
        )
    }

    package static func setRating(_ db: Database, id: Int, rating: Int, comment: String) throws {
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
    /// an 'owner' mention carrying the essence text. `said_at`/`last_mention_at`
    /// are stamped with now, the way `InsertIdeaMentionTx` does on the Go side —
    /// otherwise a hand-written idea sorts to the bottom of every
    /// `last_mention_at` list with an empty timestamp.
    @discardableResult
    package static func createManual(_ db: Database, kind: String, title: String, essence: String) throws -> Int64 {
        let now = try String.fetchOne(db, sql: "SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')") ?? ""
        try db.execute(
            sql: """
                INSERT INTO ideas (kind, title, essence, status, source, last_mention_at)
                VALUES (?, ?, ?, 'active', 'owner', ?)
                """,
            arguments: [kind, title, essence, now]
        )
        let ideaID = db.lastInsertedRowID
        try db.execute(
            sql: """
                INSERT INTO idea_mentions (idea_id, source, quote, said_at)
                VALUES (?, 'owner', ?, ?)
                """,
            arguments: [ideaID, essence, now]
        )
        return ideaID
    }

    /// Marks an idea converted into a Target, recording the link. Keeps the row,
    /// its mentions, and its chat — a link, not a delete (IDEA-03).
    package static func markConverted(_ db: Database, id: Int, targetID: Int64) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET status = 'converted', converted_target_id = ?, \(clearReviewFlag),
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [targetID, id]
        )
    }
}
