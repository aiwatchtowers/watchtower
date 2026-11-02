import Foundation

package enum PlanUsageProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex
    package var title: String { self == .claude ? "Claude" : "Codex" }
}

package enum PlanUsageStorageError: Error { case invalidSnapshot }

package enum PlanUsageWindow {
    /// Go's time.Duration stores nanoseconds in Int64; mirror its overflow gate.
    package static let maximumMinutes = 153_722_867
}

/// Endpoints published by Go. Swift never extrapolates a rate into a new point.
package struct PlanUsageLine: Codable, Equatable, Sendable {
    package let startAt: Date
    package let startPercent: Double
    package let endAt: Date
    package let endPercent: Double

    package init(startAt: Date, startPercent: Double, endAt: Date, endPercent: Double) {
        self.startAt = startAt
        self.startPercent = startPercent
        self.endAt = endAt
        self.endPercent = endPercent
    }

    package func validate(fetchedAt: Date, limit: PlanUsageLimit) throws {
        guard let reset = limit.resetsAt, let duration = limit.windowDurationMinutes,
              duration > 0, duration <= PlanUsageWindow.maximumMinutes,
              startAt == fetchedAt, startPercent == limit.percent,
              startPercent.isFinite, endPercent.isFinite,
              (0...100).contains(startPercent), (0...100).contains(endPercent),
              endAt > startAt, endAt <= reset, startAt <= reset,
              startAt >= reset.addingTimeInterval(-Double(duration) * 60)
        else { throw PlanUsageStorageError.invalidSnapshot }
    }
}

package struct PlanUsagePlot: Decodable, Equatable, Sendable {
    package let schemaVersion: Int
    package let fetchedAt: Date
    package let limits: [String: PlanUsageLine?]

    package init(schemaVersion: Int = 1, fetchedAt: Date, limits: [String: PlanUsageLine?]) {
        self.schemaVersion = schemaVersion
        self.fetchedAt = fetchedAt
        self.limits = limits
    }

    /// {} alone is the legacy default. Every other malformed shape is an error.
    package static func decode(_ text: String, fetchedAt: Date?, limits: [PlanUsageLimit]) throws -> Self? {
        let data = Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        if object.isEmpty { return nil }
        guard Set(object.keys) == ["schema_version", "fetched_at", "limits"],
              let rawLines = object["limits"] as? [String: Any],
              let timestamp = object["fetched_at"] as? String, isUTC(timestamp)
        else { throw PlanUsageStorageError.invalidSnapshot }
        let plot = try PlanUsageDates.decoder.decode(Self.self, from: data)
        guard plot.schemaVersion == 1, let fetchedAt, plot.fetchedAt == fetchedAt else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        let known = Dictionary(limits.map { ($0.key, $0) }) { first, _ in first }
        guard known.count == limits.count else { throw PlanUsageStorageError.invalidSnapshot }
        for (key, raw) in rawLines where !(raw is NSNull) {
            guard let fields = raw as? [String: Any],
                  Set(fields.keys) == ["start_at", "start_percent", "end_at", "end_percent"],
                  let start = fields["start_at"] as? String, isUTC(start),
                  let end = fields["end_at"] as? String, isUTC(end),
                  let limit = known[key], let stored = plot.limits[key], let line = stored
            else { throw PlanUsageStorageError.invalidSnapshot }
            try line.validate(fetchedAt: fetchedAt, limit: limit)
        }
        return plot
    }

    private static func isUTC(_ text: String) -> Bool { text.hasSuffix("Z") || text.hasSuffix("+00:00") }
}

package struct PlanUsageForecast: Equatable, Sendable {
    package let state: String
    package let hitAt: Date?
    package let ratePerHour: Double
    package let unavailableReason: String?
    package let line: PlanUsageLine?
    package var drawable: Bool { line != nil }
}

extension PlanUsageStatus {
    package var historyAvailable: Bool { limits.contains { !currentHistory(for: $0).isEmpty } }

    package func currentHistory(for limit: PlanUsageLimit) -> [PlanUsageSample] {
        guard let fetchedAt, let reset = limit.resetsAt, provider != .codex || identityKnown else { return [] }
        let start: Date
        if let minutes = limit.windowDurationMinutes, minutes > 0, minutes <= PlanUsageWindow.maximumMinutes {
            start = reset.addingTimeInterval(-Double(minutes) * 60)
        } else { start = fetchedAt.addingTimeInterval(-8 * 86400) }
        return history[limit.key, default: []].filter { sample in
            guard let sampleReset = sample.resetsAt else { return false }
            return sample.takenAt <= fetchedAt && sample.takenAt >= start &&
                abs(sampleReset.timeIntervalSince(reset)) <= 60 && sample.percent.isFinite && (0...100).contains(sample.percent)
        }
    }

    package func forecast(for limit: PlanUsageLimit, now: Date, enabled: Bool = true) throws -> PlanUsageForecast {
        let raw = limit.projection
        guard ["idle", "collecting", "safe", "will_hit", "hit"].contains(raw.state),
              limit.percent.isFinite, (0...100).contains(limit.percent)
        else { throw PlanUsageStorageError.invalidSnapshot }
        let candidate: PlanUsageLine?
        if let stored = plot?.limits[limit.key] { candidate = stored } else { candidate = nil }
        if let candidate {
            guard let fetchedAt else { throw PlanUsageStorageError.invalidSnapshot }
            try candidate.validate(fetchedAt: fetchedAt, limit: limit)
        }
        let reason = eligibilityReason(limit: limit, candidate: candidate, now: now, enabled: enabled)
        let rate = raw.ratePerHour.isFinite && raw.ratePerHour >= 0 ? raw.ratePerHour : 0
        return PlanUsageForecast(state: raw.state, hitAt: raw.hitAt, ratePerHour: rate,
                                 unavailableReason: reason, line: reason == nil ? candidate : nil)
    }

    private func eligibilityReason(limit: PlanUsageLimit, candidate: PlanUsageLine?, now: Date, enabled: Bool) -> String? {
        let raw = limit.projection
        if !enabled || state == "disabled" { return "disabled" }
        if let fetchedAt, fetchedAt > now.addingTimeInterval(60) { return "clock_skew" }
        guard state == "ok", let fetchedAt, now.timeIntervalSince(fetchedAt) <= 900 else { return "stale" }
        if provider == .codex && !identityKnown { return "identity_unknown" }
        guard let duration = limit.windowDurationMinutes, duration > 0, duration <= PlanUsageWindow.maximumMinutes else {
            return "missing_window_duration"
        }
        guard let reset = limit.resetsAt else { return "missing_reset" }
        guard reset > now else { return "reset_expired" }
        if ["idle", "collecting", "hit"].contains(raw.state) { return raw.state }
        guard !currentHistory(for: limit).isEmpty else { return "collecting" }
        if let hit = raw.hitAt, hit <= now { return "prediction_expired" }
        guard let candidate else { return "endpoints_unavailable" }
        return projectionMatches(limit, candidate: candidate, now: now) ? nil : "invalid_projection"
    }

    private func projectionMatches(_ limit: PlanUsageLimit, candidate: PlanUsageLine, now: Date) -> Bool {
        let raw = limit.projection
        guard raw.ratePerHour.isFinite, raw.ratePerHour >= 0, let reset = limit.resetsAt else { return false }
        if raw.state == "will_hit" {
            guard let hit = raw.hitAt else { return false }
            return raw.ratePerHour > 0 && hit > now && hit < reset && candidate.endAt == hit && candidate.endPercent == 100
        }
        guard raw.state == "safe", candidate.endAt == reset else { return false }
        if raw.ratePerHour == 0 { return candidate.endPercent == limit.percent }
        guard let hit = raw.hitAt, hit >= reset else { return false }
        return candidate.endPercent >= limit.percent
    }

}

/// Exact v1 wire envelope; its operation errors are distinct from subscription health.
package struct PlansEnvelope: Decodable, Sendable {
    package let schemaVersion: Int
    package let requestedProvider: String
    package let refreshRequested: Bool
    package let featureEnabled: Bool
    package let providers: [PlansProviderResult]

    package static func decode(_ data: Data) throws -> Self {
        try validateWireKeys(data)
        let envelope = try PlanUsageDates.decoder.decode(Self.self, from: data)
        guard envelope.schemaVersion == 1, ["all", "claude", "codex"].contains(envelope.requestedProvider) else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        let expected: [PlanUsageProvider] = envelope.requestedProvider == "all" ? [.claude, .codex] :
            PlanUsageProvider.allCases.filter { $0.rawValue == envelope.requestedProvider }
        guard envelope.providers.map(\.provider) == expected else { throw PlanUsageStorageError.invalidSnapshot }
        for result in envelope.providers {
            guard result.ok == (result.error == nil),
                  ["not_requested", "updated", "failed", "busy", "disabled", "cancelled"].contains(result.refreshOutcome)
            else { throw PlanUsageStorageError.invalidSnapshot }
            if let error = result.error, !PlansOperationError.codes.contains(error.code) {
                throw PlanUsageStorageError.invalidSnapshot
            }
            if let status = result.status { try status.validate() }
        }
        return envelope
    }

    private static func requireKeys(_ value: Any, _ keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        return object
    }

    private static func validateWireKeys(_ data: Data) throws {
        let root = try requireKeys(JSONSerialization.jsonObject(with: data),
                                   ["schema_version", "requested_provider", "refresh_requested", "feature_enabled", "providers"])
        guard let providers = root["providers"] as? [Any] else { throw PlanUsageStorageError.invalidSnapshot }
        for value in providers {
            let provider = try requireKeys(value, ["provider", "ok", "error", "refresh_outcome", "status"])
            if !(provider["error"] is NSNull) { _ = try requireKeys(provider["error"] ?? NSNull(), ["code", "message"]) }
            guard !(provider["status"] is NSNull) else { continue }
            let status = try requireKeys(provider["status"] ?? NSNull(),
                                         ["state", "reason", "plan", "fetched_at", "updated_at", "last_error", "stale",
                                          "history_available", "ordinary_usage_allowed", "limits", "breakdown"])
            guard let limits = status["limits"] as? [Any], let rows = status["breakdown"] as? [Any] else {
                throw PlanUsageStorageError.invalidSnapshot
            }
            for value in limits {
                let limit = try requireKeys(value, ["key", "label", "group", "percent", "window_duration_minutes", "resets_at", "projection"])
                let projection = try requireKeys(limit["projection"] ?? NSNull(),
                                                 ["state", "hit_at", "rate_per_hour", "drawable", "unavailable_reason", "line"])
                if !(projection["line"] is NSNull) {
                    _ = try requireKeys(projection["line"] ?? NSNull(), ["start_at", "start_percent", "end_at", "end_percent"])
                }
            }
            for row in rows { _ = try requireKeys(row, ["key", "label", "percent"]) }
        }
    }
}

package struct PlansOperationError: Decodable, Equatable, Sendable {
    package let code: String
    package let message: String
    package static let codes = ["no_credentials", "unsupported_auth", "cli_missing", "unsupported_cli", "network", "parse",
                                "storage", "busy", "feature_disabled", "cancelled", "timeout"]
    package init(code: String, message: String = "") { self.code = code; self.message = message }
}

package struct PlansProviderResult: Decodable, Sendable {
    package let provider: PlanUsageProvider
    package let ok: Bool
    package let error: PlansOperationError?
    package let refreshOutcome: String
    package let status: PlansWireStatus?
}

package struct PlansWireStatus: Decodable, Sendable {
    package let state: String
    package let reason: String
    package let plan: String
    package let fetchedAt: Date?
    package let updatedAt: Date
    package let lastError: String
    package let stale: Bool
    package let historyAvailable: Bool
    // null is a distinct source-contract value
    // swiftlint:disable:next discouraged_optional_boolean
    package let ordinaryUsageAllowed: Bool?
    package let limits: [PlansWireLimit]
    package let breakdown: [PlanUsageBreakdownRow]

    fileprivate func validate() throws {
        guard ["ok", "stale", "unavailable", "error", "disabled"].contains(state),
              Set(limits.map(\.key)).count == limits.count else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        for limit in limits {
            guard limit.percent.isFinite, (0...100).contains(limit.percent),
                  !limit.key.isEmpty,
                  limit.projection.ratePerHour.isFinite, limit.projection.ratePerHour >= 0,
                  ["idle", "collecting", "safe", "will_hit", "hit"].contains(limit.projection.state),
                  limit.projection.drawable == (limit.projection.line != nil),
                  limit.projection.drawable == (limit.projection.unavailableReason == nil)
            else { throw PlanUsageStorageError.invalidSnapshot }
            if let reason = limit.projection.unavailableReason, !Self.reasons.contains(reason) {
                throw PlanUsageStorageError.invalidSnapshot
            }
            if let line = limit.projection.line {
                guard let fetchedAt else { throw PlanUsageStorageError.invalidSnapshot }
                try line.validate(fetchedAt: fetchedAt,
                                  limit: PlanUsageLimit(key: limit.key, label: limit.label, group: limit.group, percent: limit.percent,
                                                        resetsAt: limit.resetsAt, severity: nil,
                                                        projection: PlanUsageProjection(state: limit.projection.state,
                                                                                        hitAt: limit.projection.hitAt,
                                                                                        ratePerHour: limit.projection.ratePerHour),
                                                        windowDurationMinutes: limit.windowDurationMinutes))
            }
        }
        guard breakdown.allSatisfy({ $0.percent.isFinite && (0...100).contains($0.percent) }) else {
            throw PlanUsageStorageError.invalidSnapshot
        }
    }

    private static let reasons = ["disabled", "clock_skew", "stale", "identity_unknown", "missing_window_duration", "missing_reset",
                                  "reset_expired", "idle", "collecting", "hit", "endpoints_unavailable", "invalid_projection", "prediction_expired"]
}

package struct PlansWireLimit: Decodable, Sendable {
    package let key: String
    package let label: String
    package let group: String
    package let percent: Double
    package let windowDurationMinutes: Int?
    package let resetsAt: Date?
    package let projection: PlansWireProjection
}

package struct PlansWireProjection: Decodable, Sendable {
    package let state: String
    package let hitAt: Date?
    package let ratePerHour: Double
    package let drawable: Bool
    package let unavailableReason: String?
    package let line: PlanUsageLine?

    private enum CodingKeys: String, CodingKey { case state, hitAt, ratePerHour, drawable, unavailableReason, line }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.hitAt), c.contains(.unavailableReason), c.contains(.line) else {
            throw PlanUsageStorageError.invalidSnapshot
        }
        state = try c.decode(String.self, forKey: .state)
        hitAt = try c.decodeIfPresent(Date.self, forKey: .hitAt)
        ratePerHour = try c.decode(Double.self, forKey: .ratePerHour)
        drawable = try c.decode(Bool.self, forKey: .drawable)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
        line = try c.decodeIfPresent(PlanUsageLine.self, forKey: .line)
    }
}
