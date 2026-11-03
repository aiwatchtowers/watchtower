import SwiftUI
import WatchtowerCore

/// Shared production component, also rendered by the fallback catalog fixtures.
struct ChatRoutingStatusView: View {
    let preview: ProviderFallbackPreview
    var actionEnabled = true
    var onAction: (() -> Void)?

    var body: some View {
        ProviderFallbackStatus(copy: preview.copy, actionEnabled: actionEnabled, onAction: onAction)
    }
}
