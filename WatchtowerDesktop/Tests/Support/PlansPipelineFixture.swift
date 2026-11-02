import Foundation
import GRDB
import WatchtowerCore

/// Written by the real Go app-server reader and publisher, then replayed through
/// the production Swift DB query. The bundle contains synthetic identities only.
package struct PlansPipelineFixture {
    package let now: Date
    package let status: PlanUsageStatus
    package let envelope: PlansEnvelope

    package static func load(_ db: Database) throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("internal/planusage/testdata/codex_pipeline_v1.json"))
        guard let bundle = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              bundle["schema_version"] as? Int == 1,
              let row = bundle["status"] as? [String: Any],
              let samples = bundle["samples"] as? [[String: Any]],
              let known = row["identity_known"] as? Bool,
              let ordinary = row["ordinary_usage_allowed"] as? Bool,
              let now = PlanUsageDates.preciseParse(try text(bundle, "now"))
        else { throw FixtureError.invalidBundle }
        let limits = try encoded(row, "limits")
        let plot = try encoded(row, "plot_json")
        try db.execute(sql: """
            INSERT INTO codex_plan_usage_status
              (id,state,reason,plan,fetched_at,updated_at,last_error,limits_json,breakdown_json,
               plot_json,scope,identity_known,ordinary_usage_allowed)
            VALUES (1,?,?,?,?,?,?,?,'[]',?,?,?,?)
            """, arguments: [
                try text(row, "state"),
                try text(row, "reason"),
                try text(row, "plan"),
                try text(row, "fetched_at"),
                try text(row, "updated_at"),
                try text(row, "last_error"),
                limits,
                plot,
                try text(bundle, "scope"),
                known,
                ordinary
            ])
        for sample in samples {
            guard let percent = sample["percent"] as? Double else { throw FixtureError.invalidBundle }
            try db.execute(sql: """
                INSERT INTO codex_plan_usage_samples (scope,limit_key,taken_at,percent,resets_at) VALUES (?,?,?,?,?)
                """, arguments: [
                    try text(sample, "scope"),
                    try text(sample, "limit_key"),
                    try text(sample, "taken_at"),
                    percent,
                    try text(sample, "resets_at")
                ])
        }
        guard let status = try PlanUsageQueries.status(db, provider: .codex),
              let envelope = bundle["envelope"] else { throw FixtureError.invalidBundle }
        return try Self(now: now, status: status,
                        envelope: PlansEnvelope.decode(JSONSerialization.data(withJSONObject: envelope)))
    }

    private enum FixtureError: Error { case invalidBundle }

    private static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw FixtureError.invalidBundle }
        return value
    }

    private static func encoded(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key],
              let result = String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)
        else { throw FixtureError.invalidBundle }
        return result
    }
}
