import GRDB

/// The Desktop's writes of the diff reviewer (spec §10): drafts, Resolve and
/// Viewed marks. Go owns rounds and the send transition.
package enum ReviewQueries {
    package enum ReviewQueryError: Error, Equatable { case notADraft, notResolvable, roundNotOpen }

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
        body: String,
        lens: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, quote_prefix, quote_suffix, tree_sha, lens, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [roundID, path, side, startLine, endLine, anchor.quote, anchor.prefix, anchor.suffix, treeSHA, lens, body])
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
    /// `carried` at the new lines, lost → `outdated`, an `outdated` one stays
    /// `outdated` with its quote; only `resolved` ones stay behind (REVIEW-03:
    /// none dropped).
    package static func carry(
        _ db: Database,
        from previous: [ReviewComment],
        into roundID: Int64,
        plan: ReviewCommentAnchor.Plan,
        treeSHA: String
    ) throws {
        for c in previous where c.status == .sent || c.status == .carried || c.status == .outdated {
            let place = plan.moved[c.id]
            let status = c.status == .outdated || plan.lost.contains(c.id) ? "outdated" : "carried"
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

    package static func checks(_ db: Database, roundID: Int64) throws -> [ReviewCheck] {
        try ReviewCheck.fetchAll(db, sql: """
            SELECT chapter_key, lens, item_key, state FROM review_checks WHERE round_id = ?
            ORDER BY chapter_key, lens, item_key
            """, arguments: [roundID])
    }

    /// Ticks (or re-marks) a checklist item; nil unticks. A round that is not open
    /// is read-only: it throws `roundNotOpen`, so the caller's write transaction rolls back.
    package static func setCheck(
        _ db: Database,
        roundID: Int64,
        chapterKey: String,
        lens: String,
        itemKey: String,
        state: ReviewCheck.State?
    ) throws {
        guard try Bool.fetchOne(db, sql: "SELECT status = 'open' FROM review_rounds WHERE id = ?", arguments: [roundID]) == true else {
            throw ReviewQueryError.roundNotOpen
        }
        if let state {
            try db.execute(sql: """
                INSERT INTO review_checks (round_id, chapter_key, lens, item_key, state) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (round_id, chapter_key, lens, item_key)
                DO UPDATE SET state = excluded.state, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                """, arguments: [roundID, chapterKey, lens, itemKey, state.rawValue])
        } else {
            try db.execute(sql: """
                DELETE FROM review_checks WHERE round_id = ? AND chapter_key = ? AND lens = ? AND item_key = ?
                """, arguments: [roundID, chapterKey, lens, itemKey])
        }
    }

    /// Saves the Deep-mode position of an open round; false when the round is not open.
    package static func saveRoundState(
        _ db: Database,
        roundID: Int64,
        mode: String,
        phase: ReviewPhase,
        chapterKey: String,
        activeSeconds: Int
    ) throws -> Bool {
        try db.execute(sql: """
            UPDATE review_rounds SET mode = ?, phase = ?, chapter_key = ?, active_seconds = ?
            WHERE id = ? AND status = 'open'
            """, arguments: [mode, phase.rawValue, chapterKey, max(0, activeSeconds), roundID])
        return db.changesCount == 1
    }

    // MARK: - Agent notes, undo, lessons, the agent's answers (Plan 3)

    /// The session's notes and chapters from the agent, in Go's order (kind, ord).
    package static func notes(_ db: Database, projectID: Int64, sessionID: Int64) throws -> [ReviewNote] {
        try ReviewNote.fetchAll(db, sql: """
            SELECT id, kind, ord, path, start_line, end_line, quote, text, paths_json, core, why, tree_sha
            FROM review_notes WHERE project_id = ? AND session_id = ? ORDER BY kind, ord, id
            """, arguments: [projectID, sessionID])
    }

    /// The hunks undone in the round, oldest first.
    package static func reverts(_ db: Database, roundID: Int64) throws -> [ReviewRevert] {
        try ReviewRevert.fetchAll(db, sql: """
            SELECT hunk_id, path, header, at FROM review_reverts WHERE round_id = ? ORDER BY id
            """, arguments: [roundID])
    }

    package static func proposedLessons(_ db: Database, projectID: Int64) throws -> [ReviewLesson] {
        try ReviewLesson.fetchAll(db, sql: """
            SELECT id, lens, text, source_comment_ids, status FROM review_lessons
            WHERE project_id = ? AND status = 'proposed' ORDER BY id
            """, arguments: [projectID])
    }

    /// Comments the agent answered and resolved, from the previous round and
    /// the open one; an open-round copy stands in for its source (whatever its
    /// own state — a reopened copy hides the source too).
    package static func agentResolved(_ db: Database, previousRoundID: Int64, openRoundID: Int64) throws -> [ReviewComment] {
        try ReviewComment.fetchAll(db, sql: """
            SELECT * FROM review_comments c
            WHERE c.round_id IN (?, ?) AND c.status = 'resolved' AND c.agent_reply_at IS NOT NULL
              AND NOT (c.round_id = ? AND EXISTS (
                  SELECT 1 FROM review_comments o WHERE o.round_id = ? AND o.carried_from = c.id))
            ORDER BY c.id
            """, arguments: [previousRoundID, openRoundID, previousRoundID, openRoundID])
    }

    /// Takes a comment the agent resolved back into the open round: the open
    /// copy goes back to `carried` (a copy-less draft to `draft`), a resolved
    /// source gets its copy restored or a new `carried` one. Changes nothing
    /// when the round is not open or the comment is of neither that round nor
    /// the round it follows.
    package static func reopen(_ db: Database, commentID: Int64, openRoundID: Int64) throws {
        guard try Bool.fetchOne(db, sql: "SELECT status = 'open' FROM review_rounds WHERE id = ?", arguments: [openRoundID]) == true,
              let c = try ReviewComment.fetchOne(db, sql: "SELECT * FROM review_comments WHERE id = ?", arguments: [commentID]),
              c.status == .resolved,
              try Bool.fetchOne(db, sql: """
                  SELECT ? IN (id, prev_round_id) FROM review_rounds WHERE id = ?
                  """, arguments: [c.roundID, openRoundID]) == true
        else { return }
        let touch = "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')"
        if c.roundID == openRoundID {
            try db.execute(sql: "UPDATE review_comments SET status = ?, \(touch) WHERE id = ?",
                           arguments: [c.carriedFrom == nil ? "draft" : "carried", commentID])
            return
        }
        try db.execute(sql: """
            UPDATE review_comments SET status = 'carried', \(touch)
            WHERE round_id = ? AND carried_from = ? AND status = 'resolved'
            """, arguments: [openRoundID, commentID])
        if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM review_comments WHERE round_id = ? AND carried_from = ?)",
                             arguments: [openRoundID, commentID]) != true {
            try db.execute(sql: """
                INSERT INTO review_comments (round_id, path, side, start_line, end_line, quote, quote_prefix, quote_suffix,
                    tree_sha, lens, body, status, carried_from, agent_reply, agent_reply_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'carried', ?, ?, ?)
                """, arguments: [openRoundID, c.path, c.side, c.startLine, c.endLine, c.quote, c.quotePrefix, c.quoteSuffix,
                                 c.treeSHA, c.lens, c.body, c.id, c.agentReply, c.agentReplyAt])
        }
    }
}
