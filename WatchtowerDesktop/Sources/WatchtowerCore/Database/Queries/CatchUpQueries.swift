import Foundation
import GRDB

/// DB access for Catch-Up v2 review sessions and themes. Mirrors the Go store
/// (internal/db/catchup_store.go) for reads, and the Go `Pipeline.Acknowledge`
/// cascade (internal/catchup/pipeline.go) for the per-theme mark-read.
package enum CatchUpQueries {

    // MARK: - Fetch

    /// The newest non-done / non-failed session, or nil when there is none.
    package static func fetchActiveSession(_ db: Database) throws -> CatchUpSession? {
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
    package static func fetchThemes(_ db: Database, sessionID: Int) throws -> [CatchUpTheme] {
        try CatchUpTheme.fetchAll(
            db,
            sql: "SELECT * FROM catchup_themes WHERE session_id = ? ORDER BY order_idx, id",
            arguments: [sessionID]
        )
    }

    package static func fetchTheme(_ db: Database, id: Int) throws -> CatchUpTheme? {
        try CatchUpTheme.fetchOne(db, sql: "SELECT * FROM catchup_themes WHERE id = ?", arguments: [id])
    }

    /// Reactive observation of the active session's themes (the streaming list).
    /// Emits an empty array when no session is active.
    package static func observeActiveThemes() -> ValueObservation<ValueReducers.Fetch<[CatchUpTheme]>> {
        ValueObservation.tracking { db in
            guard let session = try fetchActiveSession(db) else { return [] }
            return try fetchThemes(db, sessionID: session.id)
        }
    }

    // MARK: - Review state

    package static func setReview(_ db: Database, id: Int, state: String, snoozeUntil: String) throws {
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

    package static func setTask(_ db: Database, id: Int, taskID: Int) throws {
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
    ///
    /// Unlike the Go path, this does NOT cascade a referenced digest to its
    /// embedded decisions' `decision_reads` rows: decisions now live in the
    /// consolidated ideas ledger (`kind = 'decision'`), tracked via `seen_at`,
    /// not via a digest's raw JSON — the Swift-only Decisions feed this
    /// cascade used to protect no longer exists (decisions-split, 2026-08-12;
    /// see docs/inventory/catchup.md CATCHUP-01 changelog).
    package static func acknowledge(_ db: Database, theme: CatchUpTheme) throws {
        for ref in theme.decodedRefs {
            switch ref.area {
            case "digests":
                try DigestQueries.markDigestRead(db, id: ref.id)
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
