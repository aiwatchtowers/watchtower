import SwiftUI
import WatchtowerCore

/// Existing receipts only: opening this component never approves or runs an action.
struct ChatActionReviewView: View {
    let actions: [AgentAction]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if actions.isEmpty {
                Text(ProviderFallbackPreview.reviewEmpty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("#\(action.id) · \(action.tool) · \(action.status)").font(.caption.weight(.semibold))
                    if !action.reason.isEmpty { Text(action.reason).font(.caption) }
                    if !action.resultJSON.isEmpty { Text(action.resultJSON).font(.caption).textSelection(.enabled) }
                    if !action.error.isEmpty { Text(action.error).font(.caption).foregroundStyle(Tone.warning) }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
    }
}
