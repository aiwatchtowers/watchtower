import Foundation
import GRDB

/// DB access for Catch-Up v2 review sessions and themes. Mirrors the Go store
/// (internal/db/catchup_store.go) for reads, and the Go `Pipeline.Acknowledge`
/// cascade (internal/catchup/pipeline.go) for the per-theme mark-read.
enum CatchUpQueries {

    // MARK: - Fetch

    /// The newest non-done / non-failed session, or nil when there is none.
    static func fetchActiveSession(_ db: Database) throws -> CatchUpSession? {
        try CatchUpSession.fetchOne(
            db,
            sql: """
                SELECT * FROM catchup_sessions
                WHERE status IN ('building','active')
                ORDER BY id DESC LIMIT 1
                """
        )
    }

    /// All themes of a session in display (order_idx) order.
    static func fetchThemes(_ db: Database, sessionID: Int) throws -> [CatchUpTheme] {
        try CatchUpTheme.fetchAll(
            db,
            sql: "SELECT * FROM catchup_themes WHERE session_id = ? ORDER BY order_idx, id",
            arguments: [sessionID]
        )
    }

    static func fetchTheme(_ db: Database, id: Int) throws -> CatchUpTheme? {
        try CatchUpTheme.fetchOne(db, sql: "SELECT * FROM catchup_themes WHERE id = ?", arguments: [id])
    }

    /// Reactive observation of the active session's themes (the streaming list).
    /// Emits an empty array when no session is active.
    static func observeActiveThemes() -> ValueObservation<ValueReducers.Fetch<[CatchUpTheme]>> {
        ValueObservation.tracking { db in
            guard let session = try fetchActiveSession(db) else { return [] }
            return try fetchThemes(db, sessionID: session.id)
        }
    }

    // MARK: - Review state

    static func setReview(_ db: Database, id: Int, state: String, snoozeUntil: String) throws {
        try db.execute(
            sql: """
                UPDATE catchup_themes
                SET review_state = ?, snooze_until = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [state, snoozeUntil, id]
        )
    }

    static func setTask(_ db: Database, id: Int, taskID: Int) throws {
        try db.execute(
            sql: """
                UPDATE catchup_themes
                SET task_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [taskID, id]
        )
    }

    // MARK: - Acknowledge (cascade mark-read over refs)

    /// Cascades mark-read over the theme's snapshot refs, flips the theme to
    /// 'reviewed', and bumps the session's reviewed_count. Mirrors the Go
    /// `Pipeline.Acknowledge`: only the captured refs are cleared (snapshot by ID),
    /// unknown areas are skipped, and the mark-read calls are idempotent.
    static func acknowledge(_ db: Database, theme: CatchUpTheme) throws {
        for ref in theme.decodedRefs {
            switch ref.area {
            case "digests":
                try DigestQueries.markDigestRead(db, id: ref.id)
                // A read digest implies its decisions are read; without this the
                // Decisions feed (counted via decision_reads) strands decisions
                // already seen via catch-up. Mirrors the other markDigestRead
                // call sites and the Go MarkDigestRead cascade.
                try DigestQueries.markAllDecisionsRead(db, digestID: ref.id)
            case "tracks":
                try TrackQueries.markRead(db, id: ref.id)
            case "inbox":
                try InboxQueries.markRead(db, id: ref.id)
            case "briefings":
                try BriefingQueries.markRead(db, id: ref.id)
            default:
                break
            }
        }

        let wasReviewed = theme.isReviewed
        try setReview(db, id: theme.id, state: "reviewed", snoozeUntil: "")
        // Only count the first transition into 'reviewed' so re-acking a theme
        // never pushes reviewed_count past total_themes.
        if !wasReviewed {
            try db.execute(
                sql: "UPDATE catchup_sessions SET reviewed_count = reviewed_count + 1 WHERE id = ?",
                arguments: [theme.sessionID]
            )
        }
    }
}
