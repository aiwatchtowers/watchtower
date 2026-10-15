import Foundation
import GRDB

/// Reads of the daemon-written `plan_usage_status` / `plan_usage_samples`.
package enum PlanUsageQueries {
    package static func status(_ db: Database) throws -> PlanUsageStatus? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT state, reason, plan, fetched_at, last_error, limits_json, breakdown_json
            FROM plan_usage_status WHERE id = 1
            """) else { return nil }
        let decoder = PlanUsageDates.decoder
        let limits = (try? decoder.decode([PlanUsageLimit].self, from: Data((row["limits_json"] as String).utf8))) ?? []
        let breakdown = (try? decoder.decode([PlanUsageBreakdownRow].self, from: Data((row["breakdown_json"] as String).utf8))) ?? []
        return PlanUsageStatus(state: row["state"], reason: row["reason"], plan: row["plan"],
                               fetchedAt: PlanUsageDates.parse(row["fetched_at"]), lastError: row["last_error"],
                               limits: limits, breakdown: breakdown)
    }

    package static func samples(_ db: Database, key: String, since: Date) throws -> [PlanUsageSample] {
        let sinceText = since == .distantPast ? "" : PlanUsageDates.format(since)
        let rows = try Row.fetchAll(db, sql: """
            SELECT taken_at, percent, resets_at FROM plan_usage_samples
            WHERE limit_key = ? AND taken_at >= ? ORDER BY taken_at
            """, arguments: [key, sinceText])
        return rows.compactMap { row in
            guard let taken = PlanUsageDates.parse(row["taken_at"]) else { return nil }
            return PlanUsageSample(takenAt: taken, percent: row["percent"], resetsAt: PlanUsageDates.parse(row["resets_at"]))
        }
    }
}
