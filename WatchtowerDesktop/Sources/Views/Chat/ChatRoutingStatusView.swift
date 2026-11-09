import SwiftUI
import WatchtowerCore

/// Shared production component, also rendered by the fallback catalog fixtures.
struct ChatRoutingStatusView: View {
    let preview: ProviderFallbackPreview
    var nativeToolsNotice: String?
    var actionEnabled = true
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let nativeToolsNotice {
                Text(nativeToolsNotice).font(.caption).foregroundStyle(Tone.warning)
            }
            ProviderFallbackStatus(copy: preview.copy, actionEnabled: actionEnabled, onAction: onAction)
        }
    }
}
