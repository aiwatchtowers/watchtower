import Foundation

package struct PlansLimitPresentation: Equatable, Sendable {
    package let key: String
    package let title: String
    package let percent: String
    package let reset: String
    package let forecast: String
    package let tone: PlanUsageTone
    package let windowStart: Date?
    package let line: PlanUsageLine?
    package let history: [PlanUsageSample]
}

package struct PlansProviderPresentation: Equatable, Sendable {
    package let provider: PlanUsageProvider
    package let title: String
    package let plan: String
    package let summary: String
    package let freshness: String
    package let action: String
    package let isRefreshing: Bool
    package let isStale: Bool
    package let limits: [PlansLimitPresentation]
}

/// Copy and selection policy shared by Plans, menu bar and tray.
package enum PlansPresentation {
    package static let title = "Plans"
    package static let subtitle = "Your subscriptions, side by side"
    package static let menuToggle = "Show in the menu bar"
    package static let refreshAll = "Refresh"
    package static let weekly = "Weekly"
    package static let fiveHours = "5 hours"
    package static let chartNow = "Now"
    package static let chartReset = "Reset"

    package static func isStale(_ status: PlanUsageStatus, now: Date) -> Bool {
        guard status.state == "ok", let fetched = status.fetchedAt else { return true }
        return now.timeIntervalSince(fetched) > 900 || fetched > now.addingTimeInterval(60)
    }

    package static func duration(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Quota" }
        if minutes.isMultiple(of: 1440) { return "\(minutes / 1440)d" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    package static func reasonText(_ reason: String) -> String {
        switch reason {
        case "disabled": return "Plan limits are turned off in Features."
        case "clock_skew": return "Check your system clock, then refresh."
        case "stale": return "Refresh to update the forecast."
        case "identity_unknown": return "Current usage only — account identity is unavailable."
        case "missing_window_duration": return "This quota does not provide a window duration."
        case "missing_reset": return "Waiting for a reset time."
        case "reset_expired": return "This window has reset. Refresh to update."
        case "idle": return "Window not started"
        case "collecting": return "Collecting data…"
        case "hit": return "Limit reached"
        case "prediction_expired": return "Forecast needs an update"
        case "endpoints_unavailable": return "Refresh to load the forecast."
        default: return "Forecast unavailable. Refresh to update."
        }
    }

    package static func errorText(_ code: String, provider: PlanUsageProvider) -> String {
        switch code {
        case "cli_missing": return "Install Codex, then retry."
        case "unsupported_cli": return "Update Codex to read subscription limits, then retry."
        case "unsupported_auth": return "Sign in to Codex with a ChatGPT account, then retry."
        case "no_credentials", "token_expired", "http_401":
            return "Open \(provider == .claude ? "Claude Code" : "Codex") and sign in, then retry."
        case "feature_disabled": return reasonText("disabled")
        case "busy": return "Another refresh is running. Try again shortly."
        case "timeout": return "The refresh timed out. Try again."
        case "cancelled": return "Refresh cancelled."
        case "storage": return "Couldn't read saved limits. Retry to reload."
        case "parse": return "Couldn't read the subscription response. Retry to update."
        default: return "Couldn't update \(provider.title) limits. Retry to update."
        }
    }

    package static func limit(_ limit: PlanUsageLimit, status: PlanUsageStatus, now: Date) throws -> PlansLimitPresentation {
        let projection = try status.forecast(for: limit, now: now)
        let text: String
        if let reason = projection.unavailableReason {
            text = reasonText(reason)
        } else if projection.state == "will_hit", let hit = projection.hitAt {
            text = "At this pace you hit it at \(PlanUsagePresentation.clock(hit, now: now))"
        } else { text = "Projected below the limit at reset" }
        let resetText: String
        if let reset = limit.resetsAt {
            resetText = reset <= now ? "Reset needs an update" : PlanUsagePresentation.resetText(limit, now: now)
        } else { resetText = "Reset time unavailable" }
        let start = limit.windowDurationMinutes.flatMap { minutes -> Date? in
            guard minutes > 0, minutes <= PlanUsageWindow.maximumMinutes else { return nil }
            return limit.resetsAt?.addingTimeInterval(-Double(minutes) * 60)
        }
        let tone: PlanUsageTone = isStale(status, now: now) ? .muted :
            (limit.percent >= 100 ? .critical : (projection.drawable && projection.state == "will_hit" ? .warning : .normal))
        return PlansLimitPresentation(key: limit.key, title: limit.label,
                                      percent: PlanUsagePresentation.percentText(limit.percent), reset: resetText,
                                      forecast: text, tone: tone, windowStart: start, line: projection.line,
                                      history: status.currentHistory(for: limit))
    }

    package static func card(
        provider: PlanUsageProvider,
        status: PlanUsageStatus?,
        error: PlansOperationError?,
        refreshing: Bool,
        now: Date,
        enabled: Bool = true
    ) throws -> PlansProviderPresentation {
        let stale = !enabled || (status.map { isStale($0, now: now) } ?? true)
        let summary = cardSummary(provider: provider, status: status, error: error,
                                  refreshing: refreshing, stale: stale, enabled: enabled)
        let freshness = status?.fetchedAt.map {
            let age = max(0, Int(now.timeIntervalSince($0) / 60))
            return age == 0 ? "Updated just now" : "Updated \(age) min. ago"
        } ?? "Not updated yet"
        let items: [PlansLimitPresentation]
        if enabled, let status {
            items = try visibleLimits(status, now: now).map { try limit($0, status: status, now: now) }
        } else { items = [] }
        let needsRetry = error != nil || ["error", "unavailable"].contains(status?.state ?? "")
        let action = refreshing ? "Refreshing…" : (needsRetry ? "Retry" : "Refresh")
        return PlansProviderPresentation(provider: provider, title: provider.title, plan: status?.plan.capitalized ?? "",
                                         summary: summary, freshness: freshness, action: action,
                                         isRefreshing: refreshing, isStale: stale, limits: items)
    }

    private static func cardSummary(
        provider: PlanUsageProvider,
        status: PlanUsageStatus?,
        error: PlansOperationError?,
        refreshing: Bool,
        stale: Bool,
        enabled: Bool
    ) -> String {
        if !enabled { return reasonText("disabled") }
        if let error { return errorText(error.code, provider: provider) }
        if refreshing && status == nil { return "Loading \(provider.title) limits…" }
        guard let status else { return "No \(provider.title) plan data yet. Refresh to load limits." }
        if status.state == "disabled" { return reasonText("disabled") }
        if status.ordinaryUsageAllowed == false { return "Codex usage is currently restricted" }
        if status.state != "ok" { return errorText(status.reason, provider: provider) }
        if stale { return "Saved limits are out of date. Refresh to update." }
        if provider == .codex && !status.identityKnown { return reasonText("identity_unknown") }
        return "Subscription limits and forecast"
    }

    package static func visibleLimits(_ status: PlanUsageStatus, now: Date) -> [PlanUsageLimit] {
        if status.provider == .claude { return PlanUsagePresentation.visibleLimits(status) }
        guard !isStale(status, now: now), status.state == "ok" else { return [] }
        return status.limits
    }

    /// Approved variant A: all buckets participate; tie breaks are stable.
    package static func mostRestrictive(_ status: PlanUsageStatus, now: Date) throws -> PlanUsageLimit? {
        let limits = visibleLimits(status, now: now)
        var forecasts: [String: PlanUsageForecast] = [:]
        for limit in limits { forecasts[limit.key] = try status.forecast(for: limit, now: now) }
        return limits.min { lhs, rhs in
            let leftHit = lhs.percent >= 100, rightHit = rhs.percent >= 100
            if leftHit != rightHit { return leftHit }
            let left = forecasts[lhs.key], right = forecasts[rhs.key]
            let leftWillHit = left?.drawable == true && left?.state == "will_hit"
            let rightWillHit = right?.drawable == true && right?.state == "will_hit"
            if leftWillHit != rightWillHit { return leftWillHit }
            if leftWillHit, let a = left?.hitAt, let b = right?.hitAt, a != b { return a < b }
            if !leftHit && !leftWillHit && lhs.percent != rhs.percent { return lhs.percent > rhs.percent }
            return lhs.key < rhs.key
        }
    }

    package static func menuBar(claude: PlanUsageStatus?, codex: PlanUsageStatus?, show: Bool, now: Date) throws -> String? {
        guard show else { return nil }
        var parts: [String] = []
        var warning = false
        if let text = PlanUsagePresentation.menuBarText(claude) {
            parts.append("Claude \(text)")
            if let claude, !isStale(claude, now: now) {
                for limit in visibleLimits(claude, now: now) where ["session", "weekly_all"].contains(limit.key) {
                    let forecast = try claude.forecast(for: limit, now: now)
                    warning = warning || limit.percent >= 70 || (forecast.drawable && forecast.state == "will_hit")
                }
            }
        }
        if let codex, let chosen = try mostRestrictive(codex, now: now) {
            parts.append("Codex \(duration(chosen.windowDurationMinutes)) \(Int(chosen.percent.rounded()))%")
            let forecast = try codex.forecast(for: chosen, now: now)
            warning = warning || chosen.percent >= 100 || (forecast.drawable && forecast.state == "will_hit")
        }
        guard !parts.isEmpty else { return nil }
        return (warning ? "⚠︎ " : "") + parts.joined(separator: " · ")
    }

    package static func tray(_ status: PlanUsageStatus, now: Date) throws -> [String] {
        let limits = visibleLimits(status, now: now)
        let selected = status.provider == .claude ? ["session", "weekly_all"].compactMap { key in limits.first { $0.key == key } } : limits
        return try selected.map {
            let item = try limit($0, status: status, now: now)
            return "\(status.provider.title) · \(item.title): \(item.percent) · \(item.reset) · \(item.forecast)"
        }
    }
}
