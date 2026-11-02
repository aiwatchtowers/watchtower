import Foundation

package struct PlansMenuProvider: Identifiable, Equatable, Sendable {
    package let id: PlanUsageProvider
    package let heading: String
    package let message: String?
    package let lines: [String]
    package let action: String
    package let canRefresh: Bool
}

/// The popup retains each provider's read/refresh state even when no quota can be shown.
package struct PlansMenuPresentation: Sendable {
    package let providers: [PlansMenuProvider]
    package let openPlans = PlansScreenCopy.open

    package init(screen: PlansScreenPresentation) {
        providers = screen.providers.map { provider in
            let card = provider.presentation
            let message: String?
            if !screen.enabled {
                message = PlansPresentation.reasonText("disabled")
            } else if card.isRefreshing {
                message = provider.status == nil ? card.summary : "Refreshing \(card.title) limits…"
            } else if provider.hasError || provider.status == nil || card.isStale ||
                        provider.status?.ordinaryUsageAllowed == false || (provider.id == .codex && provider.status?.identityKnown != true) {
                message = card.summary
            } else { message = nil }
            let action: String
            if !screen.enabled {
                action = "Refresh \(card.title)"
            } else if card.isRefreshing {
                action = "Refreshing \(card.title)…"
            } else if provider.hasError || (provider.status != nil && card.isStale) {
                action = "Retry \(card.title)"
            } else {
                action = "Refresh \(card.title)"
            }
            let lines = card.limits.map { item in
                let forecast = item.forecast == message ? "" : " · \(item.forecast)"
                return "\(card.title) · \(item.title): \(item.percent) · \(item.reset)\(forecast)"
            }
            return PlansMenuProvider(id: provider.id, heading: "\(card.title) · \(card.freshness)", message: message,
                                     lines: lines, action: action, canRefresh: screen.enabled && !card.isRefreshing)
        }
    }
}
