import SwiftUI
import WatchtowerCore

/// Shared production status card for connection, quota, chat and catalog scenes.
struct ProviderFallbackStatus: View {
    let copy: ProviderFallbackPreview.Copy
    var actionEnabled = true
    var onAction: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(copy.title).font(.headline).foregroundStyle(tone)
            Text(copy.detail).font(.body).fixedSize(horizontal: false, vertical: true)
            if copy.busy { ProgressView().controlSize(.small).accessibilityLabel(copy.title) }
            if let action = copy.action, let onAction {
                Button(action, action: onAction).buttonStyle(.kitPrimary).disabled(!actionEnabled || copy.busy)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container))
        .controlSize(.small)
    }
    private var tone: Color {
        switch copy.emphasis {
        case .neutral: .secondary
        case .success: Tone.success
        case .warning: Tone.warning
        case .error: Tone.error
        }
    }
}
