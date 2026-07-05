import Foundation
import GRDB

struct InboxFeedbackQueries {
    let dbPool: DatabasePool

    // MARK: - Write

    /// Record feedback for an inbox item and atomically derive/upsert the corresponding learned rule.
    /// Mirrors Go's SubmitFeedback logic for immediate UX feedback before the daemon runs.
    func record(item: InboxItem, rating: Int, reason: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let senderID = item.senderUserID

        try dbPool.write { db in
            // Insert feedback row
            try db.execute(
                sql: """
                    INSERT INTO inbox_feedback (inbox_item_id, rating, reason, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [item.id, rating, reason, now]
            )

            // Derive rule update (mirrors Go SubmitFeedback logic — INBOX-04 gradual semantics)
            // Only (-1, never_show) writes an instant learned rule; all other ratings
            // are audit-only (the implicit learner aggregates them over time).
            switch (rating, reason) {
            case (-1, "never_show"):
                try upsertRule(
                    db,
                    ruleType: "source_mute",
                    scopeKey: "sender:\(senderID)",
                    weight: -1.0,
                    source: "user_rule",
                    now: now
                )
            case (-1, "wrong_class"):
                // Flip item class to ambient; no rule written (learner aggregates later).
                if item.itemClass == .actionable {
                    try db.execute(
                        sql: "UPDATE inbox_items SET item_class = 'ambient' WHERE id = ?",
                        arguments: [item.id]
                    )
                }
            default:
                break  // audit row only; implicit learner aggregates explicit ratings later
            }
        }
    }

    // MARK: - Private

    private func upsertRule(
        _ db: Database,
        ruleType: String,
        scopeKey: String,
        weight: Double,
        source: String,
        now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                VALUES (?, ?, ?, ?, 1, ?)
                ON CONFLICT(rule_type, scope_key) DO UPDATE SET
                    weight = excluded.weight,
                    source = excluded.source,
                    evidence_count = evidence_count + 1,
                    last_updated = excluded.last_updated
                """,
            arguments: [ruleType, scopeKey, weight, source, now]
        )
    }
}
