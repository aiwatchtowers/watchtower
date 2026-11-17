import Foundation
import GRDB

package enum IdeaQueries {

    // MARK: - Fetch

    /// Ideas of one kind (decisions excluded without one), most-recently-updated first.
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
    /// `reviewKindCond` stays alongside the caller's kind: mined decisions
    /// are born 'active' and never enter this queue whatever is asked for;
    /// only a chat-born decision waits for a verdict.
    package static func fetchForReview(_ db: Database, kind: String) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas
            WHERE (status = 'proposed' OR needs_review = 1) AND kind = ? AND \(reviewKindCond)
            ORDER BY updated_at DESC
            """, arguments: [kind])
    }

    /// Which kinds can wait in the review queue: anything but a decision,
    /// unless it was born in a chat — the dual path of Go
    /// `CountIdeasForReview` (`internal/db/ideas.go`) and `Idea.awaitsVerdict`.
    private static let reviewKindCond = "(kind != 'decision' OR chat_born = 1)"

    /// The condition every knowledge reader of the registry adds: a chat-born
    /// item is hidden while it was never approved (proposed, not now,
    /// rejected, dropped). Once approved it stays knowledge through its later
    /// life (superseded, reversed, converted, merged), as any other item does
    /// (spec §4). Twin of Go `db.KnowledgeVisibleIdeaCond("")`
    /// (`internal/db/chat_knowledge.go`); unqualified columns.
    package static let knowledgeVisibleSQL =
        "NOT (chat_born = 1 AND status IN ('proposed','not_now','rejected','dropped'))"

    /// The Inbox's Idea finder list: ideas, notes and decisions except the merged
    /// ones (F15 — decisions are informational there), newest update first.
    /// No limit (F1).
    package static func fetchInboxRegistry(_ db: Database) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas
            WHERE kind IN ('idea', 'note', 'decision') AND status != 'merged'
            ORDER BY updated_at DESC, id DESC
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

    /// Global across both kinds, unlike `fetchForReview` — the sidebar badge
    /// counts everything the owner still has to look at, whichever segment the
    /// Ideas tab happens to be on.
    package static func countForReview(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ideas
            WHERE (status = 'proposed' OR needs_review = 1) AND \(reviewKindCond)
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
    /// from the map; `decision` appears only for chat-born decisions.
    package static func reviewCountsByKind(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, COUNT(*) AS count FROM ideas
            WHERE (status = 'proposed' OR needs_review = 1) AND \(reviewKindCond)
            GROUP BY kind
            """)
        return rows.reduce(into: [:]) { counts, row in counts[row["kind"]] = row["count"] }
    }

    // MARK: - Decisions Ledger

    /// The full decisions ledger, most-recently-mentioned first (falling back
    /// to `updated_at` for a decision with no mention yet, e.g. hand-written
    /// via `createManual`). A chat-born decision joins it once approved
    /// (`knowledgeVisibleSQL`), as do the unread/new-since readers below.
    package static func fetchDecisionLedger(_ db: Database, limit: Int = 200) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas WHERE kind = 'decision' AND \(knowledgeVisibleSQL)
            ORDER BY COALESCE(NULLIF(last_mention_at, ''), updated_at) DESC
            LIMIT ?
            """, arguments: [limit])
    }

    /// Decisions still needing the owner's attention: never seen, or seen but
    /// re-flagged since (a later mention resurfaced it) — seeing a decision
    /// once doesn't excuse a fresh flag.
    package static func unreadDecisionCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ideas
            WHERE kind = 'decision' AND (seen_at IS NULL OR needs_review = 1) AND \(knowledgeVisibleSQL)
            """) ?? 0
    }

    /// Ledger decisions newer than a notification watermark, oldest first —
    /// the `DigestQueries.fetchNewSince` precedent, now over `ideas` instead
    /// of `digests`: `DigestWatcher`'s decision-notification source, since
    /// decisions are mined cross-source (Slack, Gmail, Jira, meetings) and
    /// no longer tied to a single digest.
    package static func fetchNewDecisionsSince(_ db: Database, afterID: Int) throws -> [Idea] {
        try Idea.fetchAll(db, sql: """
            SELECT * FROM ideas WHERE kind = 'decision' AND id > ? AND \(knowledgeVisibleSQL)
            ORDER BY id ASC
            """, arguments: [afterID])
    }

    package static func maxDecisionID(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT MAX(id) FROM ideas WHERE kind = 'decision' AND \(knowledgeVisibleSQL)") ?? 0
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

    // MARK: - Chat knowledge

    /// The item a chat message's knowledge prefix wrote, for the mark rebuilt
    /// when the chat reopens: the item holding the message's earliest `chat`
    /// mention (a merge carries the mention to the survivor). `nil` when none.
    package static func chatIdea(_ db: Database, conversationID: Int64, messageID: Int64) throws -> Idea? {
        try Idea.fetchOne(db, sql: """
            SELECT i.* FROM idea_mentions m JOIN ideas i ON i.id = m.idea_id
            WHERE m.source = 'chat' AND m.ref = ?
            ORDER BY m.id LIMIT 1
            """, arguments: [chatRef(conversationID: conversationID, messageID: messageID)])
    }

    /// `idea_mentions.ref` of a chat mention (see 00154).
    private static func chatRef(conversationID: Int64, messageID: Int64) -> String {
        "chat:\(conversationID):\(messageID)"
    }

}
