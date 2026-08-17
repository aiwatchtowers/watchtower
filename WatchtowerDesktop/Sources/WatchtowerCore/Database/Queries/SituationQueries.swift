import Foundation
import GRDB
import WatchtowerKit

package enum SituationQueries {

    // MARK: - Fetch

    /// Open situations ordered by rank (desc), then most-recently-updated first.
    package static func fetchFeed(_ db: Database, limit: Int, offset: Int) throws -> [Situation] {
        try Situation.fetchAll(db, sql: """
            SELECT * FROM situations
            WHERE status = 'open'
            ORDER BY rank DESC, updated_at DESC
            LIMIT ? OFFSET ?
            """, arguments: [limit, offset])
    }

    package static func fetchByID(_ db: Database, id: Int) throws -> Situation? {
        try Situation.fetchOne(db, sql: "SELECT * FROM situations WHERE id = ?", arguments: [id])
    }

    package static func openCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM situations WHERE status = 'open'") ?? 0
    }

    /// The situation's constituent inbox items (its member signals), oldest message first.
    package static func memberSignals(_ db: Database, situationID: Int) throws -> [InboxItem] {
        try InboxItem.fetchAll(db, sql: """
            SELECT inbox_items.* FROM situation_signals
            JOIN inbox_items ON inbox_items.id = situation_signals.inbox_item_id
            WHERE situation_signals.situation_id = ?
            ORDER BY inbox_items.message_ts ASC
            """, arguments: [situationID])
    }

    // MARK: - Status Updates

    package static func done(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE situations SET status = 'done', resolved_reason = 'user_done',
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [id]
        )
    }

    package static func dismiss(_ db: Database, id: Int) throws {
        try db.execute(
            sql: """
                UPDATE situations SET status = 'dismissed', resolved_reason = 'user_dismissed',
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [id]
        )
    }

    package static func snooze(_ db: Database, id: Int, until: String) throws {
        try db.execute(
            sql: """
                UPDATE situations SET status = 'snoozed', snooze_until = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [until, id]
        )
    }

    /// Marks a situation converted into a target and/or track, recording the link(s).
    package static func markConverted(_ db: Database, id: Int, targetID: Int?, trackID: Int?) throws {
        try db.execute(
            sql: """
                UPDATE situations SET status = 'converted',
                    converted_target_id = ?, converted_track_id = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [targetID, trackID, id]
        )
    }

    /// User's "Keep open" on a suggested resolution (DASH-07): clears the
    /// secretary's mark, nothing else — status untouched, no feedback call,
    /// and `updated_at` is deliberately left alone. Bumping it here would
    /// make the dashboard's feed-ordering (which tracks content changes)
    /// resurface this row right after the user said "nothing new here"; the
    /// Go-side clear on merge is fine to bump it since that path represents
    /// a real content change.
    package static func clearSuggestedResolution(_ db: Database, id: Int) throws {
        try db.execute(
            sql: "UPDATE situations SET suggested_resolution = '' WHERE id = ?",
            arguments: [id])
    }

    // MARK: - Feedback

    /// Records feedback for a situation.
    ///
    /// Rating -1: upserts a `source_mute` learned rule (weight -1.0, source 'user_rule')
    /// for each DISTINCT "channel:<id>" scope among the situation's member signals — mirrors
    /// `InboxFeedbackQueries.upsertRule`'s shape.
    /// Rating +1: no-op (audit-free v1, matches the gradual-learning contract INBOX-04).
    package static func recordFeedback(_ db: Database, situationID: Int, rating: Int) throws {
        guard rating == -1 else { return }

        let channelIDs = try String.fetchAll(db, sql: """
            SELECT DISTINCT inbox_items.channel_id FROM situation_signals
            JOIN inbox_items ON inbox_items.id = situation_signals.inbox_item_id
            WHERE situation_signals.situation_id = ?
            """, arguments: [situationID])

        let now = ISO8601DateFormatter().string(from: Date())
        for channelID in channelIDs {
            try db.execute(
                sql: """
                    INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                    VALUES ('source_mute', ?, -1.0, 'user_rule', 1, ?)
                    ON CONFLICT(rule_type, scope_key) DO UPDATE SET
                        weight = excluded.weight,
                        source = excluded.source,
                        evidence_count = evidence_count + 1,
                        last_updated = excluded.last_updated
                    """,
                arguments: ["channel:\(channelID)", now]
            )
        }
    }
}
