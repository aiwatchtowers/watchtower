import GRDB

/// The Desktop's writes of the diff reviewer (spec §10): drafts, Resolve and
/// Viewed marks. Go owns rounds and the send transition.
package enum ReviewQueries {
    package enum ReviewQueryError: Error, Equatable { case notADraft, notResolvable }

    package static func comments(_ db: Database, roundID: Int64) throws -> [ReviewComment] {
        try ReviewComment.fetchAll(db, sql: "SELECT * FROM review_comments WHERE round_id = ? ORDER BY id", arguments: [roundID])
    }

    // swiftlint:disable:next function_parameter_count
    package static func addDraft(
        _ db: Database,
        roundID: Int64,
        path: String?,
        side: String,
        startLine: Int,
        endLine: Int,
        anchor: CommentAnchor,
        treeSHA: String,
        body: String
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, quote_prefix, quote_suffix, tree_sha, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [roundID, path, side, startLine, endLine, anchor.quote, anchor.prefix, anchor.suffix, treeSHA, body])
        return db.lastInsertedRowID
    }

    package static func updateDraft(_ db: Database, id: Int64, body: String) throws {
        try db.execute(sql: """
            UPDATE review_comments SET body = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND status IN ('draft','carried')
            """, arguments: [body, id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notADraft }
    }

    package static func deleteDraft(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM review_comments WHERE id = ? AND status IN ('draft','carried')", arguments: [id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notADraft }
    }

    /// Closes a carried or outdated comment without sending it again.
    package static func resolve(_ db: Database, id: Int64) throws {
        try db.execute(sql: """
            UPDATE review_comments SET status = 'resolved', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND status IN ('carried','outdated')
            """, arguments: [id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notResolvable }
    }

    /// Moves a draft or carried comment to its re-anchored lines on a refreshed tree.
    package static func replace(_ db: Database, id: Int64, placement: ReviewCommentAnchor.Placement, treeSHA: String) throws {
        try db.execute(sql: """
            UPDATE review_comments SET start_line = ?, end_line = ?, tree_sha = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND status IN ('draft','carried')
            """, arguments: [placement.startLine, placement.endLine, treeSHA, id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notADraft }
    }

    /// Marks a draft or carried comment whose lines are gone from the refreshed tree (kept, never dropped).
    package static func markOutdated(_ db: Database, id: Int64) throws {
        try db.execute(sql: """
            UPDATE review_comments SET status = 'outdated', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ? AND status IN ('draft','carried')
            """, arguments: [id])
        guard db.changesCount == 1 else { throw ReviewQueryError.notADraft }
    }

    /// Carries the previous round's unresolved comments into roundID: moved →
    /// `carried` at the new lines, lost → `outdated` (REVIEW-03: none dropped).
    package static func carry(
        _ db: Database,
        from previous: [ReviewComment],
        into roundID: Int64,
        plan: ReviewCommentAnchor.Plan,
        treeSHA: String
    ) throws {
        for c in previous where c.status == .sent || c.status == .carried {
            let place = plan.moved[c.id]
            let status = plan.lost.contains(c.id) ? "outdated" : "carried"
            try db.execute(sql: """
                INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, quote_prefix, quote_suffix,
                    tree_sha, lens, body, status, carried_from, agent_reply)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [roundID, c.path, c.side, place?.startLine ?? c.startLine, place?.endLine ?? c.endLine,
                                 c.quote, c.quotePrefix, c.quoteSuffix, treeSHA, c.lens, c.body, status, c.id, c.agentReply])
        }
    }

    package static func viewed(_ db: Database, roundID: Int64) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT path, content_sha FROM review_viewed WHERE round_id = ?", arguments: [roundID])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["path"] as String, $0["content_sha"] as String) })
    }

    package static func setViewed(_ db: Database, roundID: Int64, path: String, contentSHA: String?) throws {
        if let contentSHA {
            try db.execute(sql: "INSERT OR REPLACE INTO review_viewed (round_id, path, content_sha) VALUES (?, ?, ?)",
                           arguments: [roundID, path, contentSHA])
        } else {
            try db.execute(sql: "DELETE FROM review_viewed WHERE round_id = ? AND path = ?", arguments: [roundID, path])
        }
    }
}
