import Foundation

package enum PlansPeriod: String, CaseIterable, Sendable {
    case weekly, session
    package var title: String { self == .weekly ? PlansPresentation.weekly : PlansPresentation.fiveHours }
    package var minutes: Int { self == .weekly ? 10080 : 300 }
}

package struct PlansScreenProvider: Identifiable, Sendable {
    package let presentation: PlansProviderPresentation
    package let status: PlanUsageStatus?
    package let summaryNeeded: Bool
    package let hasError: Bool
    package var id: PlanUsageProvider { presentation.provider }
    package var planLabel: String { id == .codex && presentation.limits.isEmpty ? "" : presentation.plan }
    package var primary: PlansLimitPresentation? {
        presentation.limits.first { duration($0) == 10080 } ?? presentation.limits.first
    }
    package var showsSummary: Bool { summaryNeeded && presentation.summary != primary?.forecast }
    package var session: PlansLimitPresentation? { presentation.limits.first { duration($0) == 300 } }
    package var otherLimits: [PlansLimitPresentation] {
        presentation.limits.filter { $0.key != primary?.key && $0.key != session?.key }
    }
    package func selected(_ period: PlansPeriod) -> PlansLimitPresentation? {
        presentation.limits.first { duration($0) == period.minutes }
    }
    package func reset(for limit: PlansLimitPresentation) -> Date? { status?.limits.first { $0.key == limit.key }?.resetsAt }
    private func duration(_ item: PlansLimitPresentation) -> Int? {
        status?.limits.first { $0.key == item.key }?.windowDurationMinutes
    }
}

package struct PlansScreenPresentation: Sendable {
    package let providers: [PlansScreenProvider]
    package let now: Date
    package let enabled: Bool
    package var isRefreshing: Bool { enabled && providers.contains { $0.presentation.isRefreshing } }
    package var hasLimits: Bool { providers.contains { !$0.presentation.limits.isEmpty } }
    package var hasDetails: Bool {
        providers.contains { !$0.otherLimits.isEmpty ||
            ($0.id == .claude && !$0.presentation.limits.isEmpty && $0.status?.breakdown.isEmpty == false)
        }
    }
    package var isLoading: Bool { isRefreshing && !hasLimits }
    package var hasUnavailableForecast: Bool { providers.contains { $0.primary?.unavailableReason != nil } }
    package var refreshTitle: String { isRefreshing ? "Refreshing…" : PlansPresentation.refreshAll }
    package var statusTitle: String {
        if !enabled { return PlansPresentation.reasonText("disabled") }
        if isLoading { return "Reading your plan limits…" }
        if isRefreshing { return "Refreshing your plans" }
        if !hasLimits, providers.contains(where: \.hasError) { return "Plan limits couldn't be read" }
        if !hasLimits { return "Bring your plans together" }
        if let restricted = providers.first(where: { $0.status?.ordinaryUsageAllowed == false }) {
            return restricted.presentation.summary
        }
        if let hit = providers.first(where: { $0.presentation.limits.contains { $0.tone == .critical } }) {
            return "\(hit.presentation.title) limit reached"
        }
        if let warning = providers.first(where: { $0.presentation.limits.contains { $0.tone == .warning || $0.tone == .critical } }) {
            return "\(warning.presentation.title) may run out before reset"
        }
        if let only = soleAvailableProvider { return "Showing \(only.presentation.title) only" }
        if providers.contains(where: { $0.presentation.isStale }) { return "Some providers need attention" }
        let reasons = providers.compactMap { $0.primary?.unavailableReason }
        if reasons.contains("prediction_expired") { return "Forecast needs an update" }
        if reasons.count == providers.count, reasons.allSatisfy({ $0 == "collecting" }) { return "Collecting forecast data…" }
        if reasons.count == providers.count, reasons.allSatisfy({ $0 == "idle" }) { return "Waiting for a usage window" }
        if !reasons.isEmpty { return "Some forecasts are unavailable" }
        return "Your plan limits are up to date"
    }
    package var statusDetail: String {
        if !enabled { return "Turn on plan limits in Features to refresh both subscriptions." }
        if isLoading { return "Reading subscription allowances from Claude and Codex." }
        if isRefreshing { return "Keeping current values visible while providers update independently." }
        if !hasLimits, providers.contains(where: \.hasError) {
            return "Check each provider's message, then retry. Providers update independently."
        }
        if !hasLimits { return "Sign in to Claude Code or Codex, then refresh to load your subscription limits." }
        if let only = soleAvailableProvider {
            let missing = only.id == .claude ? PlanUsageProvider.codex : .claude
            return "\(missing.title) limits aren't available yet. Refresh \(missing.title) to add them."
        }
        return "Subscription percentages are tracked separately. Each forecast ends at its own reset."
    }
    package var warning: Bool {
        providers.contains { $0.hasError || ($0.status != nil && $0.presentation.isStale) ||
            $0.presentation.limits.contains { $0.tone == .warning || $0.tone == .critical }
        }
    }

    private var soleAvailableProvider: PlansScreenProvider? {
        let available = providers.filter { !$0.presentation.limits.isEmpty }
        guard available.count == 1, providers.contains(where: { $0.status == nil && !$0.hasError }) else { return nil }
        return available.first
    }

    package init(
        claude: PlanUsageStatus?,
        codex: PlanUsageStatus?,
        errors: [PlanUsageProvider: PlansOperationError] = [:],
        refreshing: Set<PlanUsageProvider> = [],
        now: Date,
        enabled: Bool = true
    ) {
        self.now = now
        self.enabled = enabled
        providers = PlanUsageProvider.allCases.map { provider in
            let status = provider == .claude ? claude : codex
            let isRefreshing = enabled && refreshing.contains(provider)
            do {
                let card = try PlansPresentation.card(provider: provider, status: status, error: errors[provider],
                                                      refreshing: isRefreshing, now: now, enabled: enabled)
                let hasError = errors[provider] != nil || ["error", "unavailable"].contains(status?.state ?? "")
                let showsSummary = hasError || card.isStale || status?.ordinaryUsageAllowed == false ||
                    (provider == .codex && status?.identityKnown != true)
                return PlansScreenProvider(presentation: card, status: status, summaryNeeded: showsSummary, hasError: hasError)
            } catch {
                // One invalid snapshot must not suppress the other subscription.
                let card = PlansProviderPresentation(provider: provider, title: provider.title, plan: "",
                                                     summary: PlansPresentation.errorText("storage", provider: provider),
                                                     freshness: "Not updated yet",
                                                     action: "Retry", isRefreshing: isRefreshing, isStale: true, limits: [])
                return PlansScreenProvider(presentation: card, status: nil, summaryNeeded: true, hasError: true)
            }
        }
    }
}

package enum PlansScreenCopy {
    package static let tabsTitle = "Statistics"
    package static let heading = "Plans & limits"
    package static let subtitle = "Your subscriptions, in one place."
    package static let used = "used"
    package static let history = "This week"
    package static let historyNote = "Solid: usage so far · Dashed: forecast at your current pace"
    package static let periodTitle = "Limit window"
    package static let menu = "Show limits in the menu bar"
    package static let footer = "Subscription percentages are tracked separately. API costs live in Watchtower."
    package static let otherLimits = "Additional limits"
    package static let breakdown = "Claude usage by surface"
    package static let open = "Open Plans"
    package static let unavailable = "Usage history is unavailable for this window."
    package static let axes = ["100%", "50%", "0%"]
    package static func missingWindow(_ period: PlansPeriod) -> String {
        "This subscription does not provide a \(period == .weekly ? "weekly" : "5-hour") limit."
    }
    package static func windowTitle(_ period: PlansPeriod) -> String { period == .weekly ? "Weekly usage" : "5-hour window" }
    package static func historyTitle(_ period: PlansPeriod) -> String { period == .weekly ? history : "5-hour history" }
    package static func date(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
    package static func resetDate(_ date: Date) -> String { "Reset · " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    package static func hitLabel(_ line: PlanUsageLine) -> String {
        "100% reached · " + line.endAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    package static func chartCaption(_ item: PlansLimitPresentation) -> String {
        if let line = item.line, item.tone == .warning { return hitLabel(line) }
        return item.forecast
    }
    package static func providerAction(_ card: PlansProviderPresentation) -> String {
        card.isRefreshing ? "Refreshing \(card.title)…" : "\(card.action) \(card.title)"
    }
}
