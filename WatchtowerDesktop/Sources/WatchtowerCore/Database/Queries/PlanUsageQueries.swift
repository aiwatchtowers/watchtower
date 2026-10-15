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
        let limits: [PlanUsageLimit] = decodeList(decoder, column: "limits_json", row: row)
        let breakdown: [PlanUsageBreakdownRow] = decodeList(decoder, column: "breakdown_json", row: row)
        return PlanUsageStatus(state: row["state"], reason: row["reason"], plan: row["plan"],
                               fetchedAt: PlanUsageDates.parse(row["fetched_at"]), lastError: row["last_error"],
                               limits: limits, breakdown: breakdown)
    }

    /// An undecodable column degrades to `[]` (the state and banner still show)
    /// but is logged: a read error would freeze the whole status on the old row.
    private static func decodeList<T: Decodable>(_ decoder: JSONDecoder, column: String, row: Row) -> [T] {
        let text: String = row[column]
        do {
            return try decoder.decode([T].self, from: Data(text.utf8))
        } catch {
            NSLog("PlanUsageQueries: %@ is undecodable: %@", column, String(describing: error))
            return []
        }
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
