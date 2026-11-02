import SwiftUI
import WatchtowerCore

/// Keeps the persisted destination while displaying both subscriptions.
struct ClaudePlanView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PlanUsageCenter.menuBarKey) private var showInMenuBar = true
    @State private var period = PlansPeriod.weekly

    var body: some View {
        if let center = appState.planUsageCenter {
            PlansContent(model: center.screenPresentation, period: $period, showInMenuBar: $showInMenuBar,
                         refresh: { provider in Task { await center.refresh(provider) } },
                         refreshAll: { Task { await center.refresh() } })
        } else {
            PlansContent(model: PlansScreenPresentation(claude: nil, codex: nil,
                                                        refreshing: Set(PlanUsageProvider.allCases), now: .now),
                         period: $period, showInMenuBar: $showInMenuBar, refresh: { _ in }, refreshAll: {})
        }
    }

}
