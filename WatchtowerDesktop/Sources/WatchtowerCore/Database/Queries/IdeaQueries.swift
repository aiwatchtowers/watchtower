import Foundation
import GRDB

package enum IdeaQueries {

    // MARK: - Fetch

    /// Ideas filtered by kind/status and a free-text query, most-recently-updated first.
    /// The query matches an idea's title/essence or any of its mentions' quotes.
    ///
    /// `excludingReviewQueue` drops what `fetchForReview` already returns —
    /// mirroring `Idea.isForReview` in SQL. Filtering those out in Swift after
    /// the fact silently shrinks the page: with the limit spent on review items
    /// the registry list comes back short, and worse as the queue grows.
    ///
    /// The Ideas tab never shows decisions — with no explicit `kind`, decisions
    /// are excluded; the Decisions ledger passes `kind: "decision"` explicitly
    /// to see them.
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
        } else {
            conditions.append("kind != 'decision'")
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

    /// Ideas awaiting owner review, scoped to one kind — the Ideas tab's
    /// Ideas/Notes segments each review their own queue, so a flagged note
    /// surfaces under Notes instead of mixing into Ideas.
    ///
    /// The `kind != 'decision'` clause stays alongside the caller's kind:
    /// decisions are born 'active' and never enter this queue whatever is
    /// asked for — mirrors the Go side's `CountIdeasForReview`, which this is
    /// the dual path of.
    package static func fetchForReview(_ db: Database, kind: String) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas
            WHERE (status = 'proposed' OR needs_review = 1) AND kind = ? AND kind != 'decision'
            ORDER BY updated_at DESC
            """, arguments: [kind])
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

    /// Global across both kinds, unlike `fetchForReview` — the sidebar badge
    /// counts everything the owner still has to look at, whichever segment the
    /// Ideas tab happens to be on.
    package static func countForReview(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ideas
            WHERE (status = 'proposed' OR needs_review = 1) AND kind != 'decision'
            """) ?? 0
    }

    /// Everything the Ideas tab can show, across both segments — what the
    /// full-screen "No ideas yet" state keys off. Keying it off the active
    /// segment instead would hide the segmented control (which lives in the
    /// filter bar the empty state replaces) with no way back to the other one.
    package static func countIdeasAndNotes(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ideas WHERE kind IN ('idea', 'note')") ?? 0
    }

    /// Review-queue size per kind, keyed by `kind` — what the Ideas | Notes
    /// segment labels count, so a queue waiting in the other segment is
    /// visible without switching to it. A kind with nothing waiting is absent
    /// from the map.
    package static func reviewCountsByKind(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, COUNT(*) AS count FROM ideas
            WHERE (status = 'proposed' OR needs_review = 1) AND kind IN ('idea', 'note')
            GROUP BY kind
            """)
        return rows.reduce(into: [:]) { counts, row in counts[row["kind"]] = row["count"] }
    }

    // MARK: - Decisions Ledger

    /// The full decisions ledger, most-recently-mentioned first (falling back
    /// to `updated_at` for a decision with no mention yet, e.g. hand-written
    /// via `createManual`).
    package static func fetchDecisionLedger(_ db: Database, limit: Int = 200) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas WHERE kind = 'decision'
            ORDER BY COALESCE(NULLIF(last_mention_at, ''), updated_at) DESC
            LIMIT ?
            """, arguments: [limit])
    }

    /// Stamps a single decision as seen by the owner. Seeing IS the owner
    /// looking at it, so this also clears any pending review flag (IDEA-04) —
    /// the same contract `setStatus`/`snooze`/`merge`/`supersede`/
    /// `markConverted` uphold via `clearReviewFlag`.
    package static func markDecisionSeen(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE ideas SET seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), \(clearReviewFlag)
                WHERE id = ?
                """,
            arguments: [id]
        )
    }

    /// Stamps every decision the owner hasn't caught up on as seen, leaving an
    /// already-seen-and-not-re-flagged row's `seen_at` untouched. Matches
    /// `unreadDecisionCount`'s predicate exactly: never seen, or seen but
    /// re-flagged since — a "mark all seen" that skipped re-flagged rows would
    /// leave them stuck showing unread with no way to clear them in bulk.
    /// Also clears any pending review flag on the rows it touches (IDEA-04) —
    /// see `markDecisionSeen`.
    package static func markAllDecisionsSeen(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE ideas SET seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), \(clearReviewFlag)
            WHERE kind = 'decision' AND (seen_at IS NULL OR needs_review = 1)
            """)
    }

    /// Decisions still needing the owner's attention: never seen, or seen but
    /// re-flagged since (a later mention resurfaced it) — seeing a decision
    /// once doesn't excuse a fresh flag.
    package static func unreadDecisionCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ideas
            WHERE kind = 'decision' AND (seen_at IS NULL OR needs_review = 1)
            """) ?? 0
    }

    /// Ledger decisions newer than a notification watermark, oldest first —
    /// the `DigestQueries.fetchNewSince` precedent, now over `ideas` instead
    /// of `digests`: `DigestWatcher`'s decision-notification source, since
    /// decisions are mined cross-source (Slack, Gmail, Jira, meetings) and
    /// no longer tied to a single digest.
    package static func fetchNewDecisionsSince(_ db: Database, afterID: Int) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas WHERE kind = 'decision' AND id > ?
            ORDER BY id ASC
            """, arguments: [afterID])
    }

    package static func maxDecisionID(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT MAX(id) FROM ideas WHERE kind = 'decision'") ?? 0
    }

    /// Distinct mention sources per idea, for the decisions ledger row's
    /// compact source glyphs (spec B3: "title, source glyphs from mentions,
    /// relative time, unread dot"). One row per idea via `GROUP_CONCAT
    /// (DISTINCT source)` — cheap for the ledger's ≤200-row cap, avoids
    /// fetching every mention just to read its `source` column.
    package static func mentionSourcesByIdea(_ db: Database, ids: [Int]) throws -> [Int: [String]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT idea_id, GROUP_CONCAT(DISTINCT source) AS sources
            FROM idea_mentions
            WHERE idea_id IN (\(placeholders))
            GROUP BY idea_id
            """, arguments: StatementArguments(ids))
        var result: [Int: [String]] = [:]
        for row in rows {
            let ideaID: Int = row["idea_id"]
            let sourcesRaw: String = row["sources"] ?? ""
            result[ideaID] = sourcesRaw.isEmpty ? [] : sourcesRaw.split(separator: ",").map(String.init)
        }
        return result
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

    /// Owner-initiated hard delete: the row, its mentions, and its Discuss
    /// chat, in the caller's single write transaction (the
    /// `MeetingTranscriptQueries.delete` precedent). Deliberately outside
    /// IDEA-03, which governs the convert/merge *transitions* — those stay
    /// links; this is the owner explicitly throwing an entry away.
    ///
    /// Anything merged into the deleted entry goes with it, recursively. A
    /// merged row's mentions were re-parented onto the survivor at merge time
    /// (IDEA-03), so what it leaves behind is a provenance-less husk whose
    /// only content is the `merged_into_id` redirect the Go consolidator
    /// follows one hop (`applyAttachMentionOp`). Keeping those husks after
    /// their survivor is gone would point that redirect at a row that no
    /// longer exists, landing repeat mentions on a dead `status='merged'`
    /// entry the owner can no longer see.
    package static func delete(_ db: Database, id: Int) throws {
        // UNION (not UNION ALL) so a merge cycle terminates rather than
        // recursing forever. The seed is returned whether or not it exists,
        // making a delete of an unknown id a clean no-op.
        let doomed = try Int.fetchAll(db, sql: """
            WITH RECURSIVE doomed(id) AS (
                SELECT ?
                UNION
                SELECT ideas.id FROM ideas JOIN doomed ON ideas.merged_into_id = doomed.id
            )
            SELECT id FROM doomed
            """, arguments: [id])

        for doomedID in doomed {
            if let conversation = try ChatConversationQueries.fetchByContext(db, type: "idea", id: String(doomedID)) {
                // Mirrors ChatMessageQueries.deleteByConversation, which lives
                // in the app target and isn't reachable from Core.
                try db.execute(sql: "DELETE FROM chat_messages WHERE conversation_id = ?", arguments: [conversation.id])
                try ChatConversationQueries.delete(db, id: conversation.id)
            }
            // Explicit, though the FK is ON DELETE CASCADE — independent of
            // the connection's foreign_keys pragma.
            try db.execute(sql: "DELETE FROM idea_mentions WHERE idea_id = ?", arguments: [doomedID])
            try db.execute(sql: "DELETE FROM ideas WHERE id = ?", arguments: [doomedID])
        }

        // Neither column carries a foreign key, so a survivor pointing into
        // what was just deleted would keep a dangling link. `merged_into_id`
        // needs no such pass: every row that could point into the chain is
        // itself in `doomed`.
        let placeholders = doomed.map { _ in "?" }.joined(separator: ",")
        let survivorArgs = StatementArguments(doomed)
        try db.execute(
            sql: "UPDATE ideas SET similar_to_id = NULL WHERE similar_to_id IN (\(placeholders))",
            arguments: survivorArgs
        )
        try db.execute(
            sql: "UPDATE ideas SET superseded_by_id = NULL WHERE superseded_by_id IN (\(placeholders))",
            arguments: survivorArgs
        )
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
