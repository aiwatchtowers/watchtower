import SwiftUI
import WatchtowerCore

/// Shared production component, also rendered by the fallback catalog fixtures.
struct ChatRoutingStatusView: View {
    let preview: ProviderFallbackPreview
    var actionEnabled = true
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(preview.copy.title).font(.headline).foregroundStyle(tone)
            Text(preview.copy.detail).fixedSize(horizontal: false, vertical: true)
            if let label = preview.copy.action, let onAction {
                Button(label, action: onAction).buttonStyle(.kitPrimary).disabled(!actionEnabled)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
        .controlSize(.small)
    }

    private var tone: Color {
        switch preview.copy.emphasis {
        case .neutral: .secondary
        case .success: Tone.success
        case .warning: Tone.warning
        case .error: Tone.error
        }
    }
}
