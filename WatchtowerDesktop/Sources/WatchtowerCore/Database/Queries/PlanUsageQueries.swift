import Foundation
import GRDB

/// Independent reads of published provider snapshots. Go owns writes.
package enum PlanUsageQueries {
    package static func status(_ db: Database, provider: PlanUsageProvider = .claude) throws -> PlanUsageStatus? {
        let table = provider == .claude ? "plan_usage_status" : "codex_plan_usage_status"
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = 1") else { return nil }
        let state: String = row["state"]
        guard ["ok", "stale", "unavailable", "error", "disabled"].contains(state) else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        let fetched = try date(row["fetched_at"])
        let updated = try date(row["updated_at"])
        let decoder = PlanUsageDates.decoder
        let encoded: String = row["limits_json"]
        var limits = try decoder.decode([PlanUsageLimit].self, from: Data(encoded.utf8))
        if provider == .claude {
            limits = limits.map { limit in
                PlanUsageLimit(key: limit.key, label: limit.label, group: limit.group, percent: limit.percent,
                               resetsAt: limit.resetsAt, severity: limit.severity, projection: limit.projection,
                               windowDurationMinutes: limit.group == "session" ? 300 : (limit.group == "weekly" ? 10080 : nil))
            }
        }
        guard Set(limits.map(\.key)).count == limits.count,
              limits.allSatisfy({ !$0.key.isEmpty && $0.percent.isFinite && (0...100).contains($0.percent) &&
                  ["idle", "collecting", "safe", "will_hit", "hit"].contains($0.projection.state) })
        else { throw PlanUsageStorageError.invalidSnapshot }
        let plot = try PlanUsagePlot.decode(row["plot_json"], fetchedAt: fetched, limits: limits)
        let breakdownText: String = row["breakdown_json"]
        let breakdown = try decoder.decode([PlanUsageBreakdownRow].self, from: Data(breakdownText.utf8))
        guard breakdown.allSatisfy({ $0.percent.isFinite && (0...100).contains($0.percent) }) else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        let known: Bool = provider == .claude || row["identity_known"]
        let scope: String = provider == .codex ? row["scope"] : ""
        guard provider == .claude || (known ? scope.count == 64 : scope.isEmpty) else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        // SQL NULL is unknown, not allowed
        // swiftlint:disable:next discouraged_optional_boolean
        let ordinary: Bool? = provider == .codex ? row["ordinary_usage_allowed"] : nil
        var history: [String: [PlanUsageSample]] = [:]
        for limit in limits where known {
            guard let fetched, let reset = limit.resetsAt else { continue }
            let duration = limit.windowDurationMinutes.flatMap { $0 > 0 && $0 <= PlanUsageWindow.maximumMinutes ? $0 : nil }
            let since = duration.map { reset.addingTimeInterval(-Double($0) * 60) } ?? fetched.addingTimeInterval(-8 * 86400)
            history[limit.key] = try publishedSamples(
                db,
                provider: provider,
                scope: scope,
                key: limit.key,
                since: since,
                fetched: fetched,
                reset: reset
            )
        }
        if provider == .codex && !known && state != "ok" { limits = [] }
        return PlanUsageStatus(state: state, reason: row["reason"], plan: row["plan"], fetchedAt: fetched,
                               lastError: row["last_error"], limits: limits, breakdown: breakdown,
                               provider: provider, updatedAt: updated, identityKnown: known,
                               ordinaryUsageAllowed: ordinary, plot: plot, history: history)
    }

    private static func date(_ text: String?) throws -> Date? {
        guard let text, !text.isEmpty else { return nil }
        guard let result = PlanUsageDates.preciseParse(text) else { throw PlanUsageStorageError.invalidSnapshot }
        return result
    }

    private static func publishedSamples(
        _ db: Database,
        provider: PlanUsageProvider,
        scope: String,
        key: String,
        since: Date,
        fetched: Date,
        reset: Date
    ) throws -> [PlanUsageSample] {
        let table = provider == .claude ? "plan_usage_samples" : "codex_plan_usage_samples"
        let scopeClause = provider == .codex ? "AND scope = ?" : ""
        var values: [DatabaseValueConvertible] = [
            key,
            PlanUsageDates.format(since),
            PlanUsageDates.format(fetched),
            PlanUsageDates.format(reset.addingTimeInterval(-60)),
            PlanUsageDates.format(reset.addingTimeInterval(60))
        ]
        if provider == .codex { values.append(scope) }
        let rows = try Row.fetchAll(db, sql: """
            SELECT taken_at, percent, resets_at FROM \(table)
            WHERE limit_key = ? AND taken_at >= ? AND taken_at <= ?
              AND resets_at >= ? AND resets_at <= ? \(scopeClause) ORDER BY taken_at
            """, arguments: StatementArguments(values))
        return try rows.map(decodeSample)
    }

    private static func decodeSample(_ row: Row) throws -> PlanUsageSample {
        guard let taken = try date(row["taken_at"]) else { throw PlanUsageStorageError.invalidSnapshot }
        let percent: Double = row["percent"]
        guard percent.isFinite, (0...100).contains(percent) else { throw PlanUsageStorageError.invalidSnapshot }
        return PlanUsageSample(takenAt: taken, percent: percent, resetsAt: try date(row["resets_at"]))
    }

    /// Archival query; Plans consumes only snapshot-bound `status.history`.
    package static func samples(_ db: Database, key: String, since: Date) throws -> [PlanUsageSample] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT taken_at, percent, resets_at FROM plan_usage_samples
            WHERE limit_key = ? AND taken_at >= ? ORDER BY taken_at
            """, arguments: [key, since == .distantPast ? "" : PlanUsageDates.format(since)])
        return try rows.map(decodeSample)
    }
}
