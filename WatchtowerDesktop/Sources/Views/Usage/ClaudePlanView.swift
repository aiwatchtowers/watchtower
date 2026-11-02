import SwiftUI
import WatchtowerCore

/// Keeps the persisted destination while displaying both subscriptions.
struct ClaudePlanView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PlanUsageCenter.menuBarKey) private var showInMenuBar = true
    @State private var period = PlansPeriod.weekly

    var body: some View {
        if let center = appState.planUsageCenter {
            PlansContent(model: model(center), period: $period, showInMenuBar: $showInMenuBar,
                         refresh: { provider in Task { await center.refresh(provider) } },
                         refreshAll: { Task { await center.refresh() } })
        } else {
            PlansContent(model: PlansScreenPresentation(claude: nil, codex: nil,
                                                        refreshing: Set(PlanUsageProvider.allCases), now: .now),
                         period: $period, showInMenuBar: $showInMenuBar, refresh: { _ in }, refreshAll: {})
        }
    }

    private func model(_ center: PlanUsageCenter) -> PlansScreenPresentation {
        var errors: [PlanUsageProvider: PlansOperationError] = [:]
        for provider in PlanUsageProvider.allCases { errors[provider] = center.providerError(provider) }
        let loading = Set(PlanUsageProvider.allCases.filter { !center.loadedProviders.contains($0) })
        return PlansScreenPresentation(claude: center.status, codex: center.codexStatus, errors: errors,
                                       refreshing: center.refreshingProviders.union(loading),
                                       now: center.presentationNow, enabled: center.featureEnabled)
    }
}
