import Foundation
import WatchtowerCore

extension PlanUsageCenter {
    /// The screen and menu share provider errors, initial loading and the polling clock.
    var screenPresentation: PlansScreenPresentation {
        var errors: [PlanUsageProvider: PlansOperationError] = [:]
        for provider in PlanUsageProvider.allCases { errors[provider] = providerError(provider) }
        let loading = Set(PlanUsageProvider.allCases.filter { !loadedProviders.contains($0) })
        return PlansScreenPresentation(claude: status, codex: codexStatus, errors: errors,
                                       refreshing: refreshingProviders.union(loading),
                                       now: presentationNow, enabled: featureEnabled)
    }
}
