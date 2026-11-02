import SwiftUI
import WatchtowerCore

/// The actual NSMenu plan items, also hosted by the production design shots.
struct PlansTrayRows: View {
    let model: PlansMenuPresentation
    let openPlans: () -> Void
    let refresh: (PlanUsageProvider) -> Void

    var body: some View {
        ForEach(model.providers) { provider in
            Text(provider.heading)
            if let message = provider.message { Text(message) }
            ForEach(Array(provider.lines.enumerated()), id: \.offset) { _, line in
                Button(line, action: openPlans)
            }
            Button(provider.action) { refresh(provider.id) }.disabled(!provider.canRefresh)
        }
        Button(model.openPlans, action: openPlans)
    }
}
