import Foundation

/// Projection of when a limit will be hit. Mirrors the Go `planusage`
/// projection written into `plan_usage_status.limits_json`.
package struct PlanUsageProjection: Codable, Equatable, Sendable {
    /// idle | collecting | safe | will_hit | hit
    package let state: String
    package let hitAt: Date?
    package let ratePerHour: Double

    package init(state: String, hitAt: Date?, ratePerHour: Double) {
        self.state = state
        self.hitAt = hitAt
        self.ratePerHour = ratePerHour
    }
}

/// One limit row of the Claude plan (5-hour session, weekly, scoped weekly).
package struct PlanUsageLimit: Codable, Equatable, Identifiable, Sendable {
    package let key: String
    package let label: String
    package let group: String
    package let percent: Double
    package let resetsAt: Date?
    package let severity: String?
    package let projection: PlanUsageProjection
    package var id: String { key }

    package init(
        key: String,
        label: String,
        group: String,
        percent: Double,
        resetsAt: Date?,
        severity: String?,
        projection: PlanUsageProjection
    ) {
        self.key = key
        self.label = label
        self.group = group
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.projection = projection
    }
}

package struct PlanUsageBreakdownRow: Codable, Equatable, Identifiable, Sendable {
    package let key: String
    package let label: String
    package let percent: Double
    package var id: String { key }

    package init(key: String, label: String, percent: Double) {
        self.key = key
        self.label = label
        self.percent = percent
    }
}

/// The singleton `plan_usage_status` row. Go owns every write.
package struct PlanUsageStatus: Equatable, Sendable {
    /// ok | stale | unavailable | error | disabled
    package let state: String
    package let reason: String
    package let plan: String
    package let fetchedAt: Date?
    package let lastError: String
    package let limits: [PlanUsageLimit]
    package let breakdown: [PlanUsageBreakdownRow]

    package init(
        state: String,
        reason: String,
        plan: String,
        fetchedAt: Date?,
        lastError: String,
        limits: [PlanUsageLimit],
        breakdown: [PlanUsageBreakdownRow]
    ) {
        self.state = state
        self.reason = reason
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.lastError = lastError
        self.limits = limits
        self.breakdown = breakdown
    }
}

/// One `plan_usage_samples` row.
package struct PlanUsageSample: Equatable, Sendable {
    package let takenAt: Date
    package let percent: Double
    package let resetsAt: Date?

    package init(takenAt: Date, percent: Double, resetsAt: Date?) {
        self.takenAt = takenAt
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// Date helpers shared by the queries and the JSON decoder. Go writes
/// RFC3339Nano (up to 9 fractional digits), which `ISO8601DateFormatter`
/// rejects, so the fraction is stripped before parsing.
package enum PlanUsageDates {
    package static func parse(_ text: String?) -> Date? {
        guard var s = text, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            s.removeSubrange(dot..<end)
        }
        return formatter.date(from: s)
    }

    /// Whole-second UTC, the fixed-width form Go stores in the sample table.
    package static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    package static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Invalid date: \(text)"))
            }
            return date
        }
        return d
    }

    private static var formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}
