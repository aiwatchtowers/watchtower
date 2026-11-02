import SwiftUI
import WatchtowerCore

/// Settings → Mobile while Mobile moves to the Go hub (go hub plan 3
/// Task 22, mockup sections 4–6): loading with its skeleton row, the
/// hand-over's step with its bar, or the failure with **Retry** (and, for
/// missing keys, **Set up Mobile again** after the owner confirms). Nothing
/// else on the tab is usable until it ends. Every string comes from
/// `HubAdoptionState`.
struct MobileHandOverView: View {
    let state: HubAdoptionState
    let onRetry: () -> Void
    var onSetUpAgain: () -> Void = {}
    @State private var confirmingSetUpAgain = false

    var body: some View {
        SettingsSection(title: HubAdoptionState.sectionTitle) {
            HStack(alignment: .center, spacing: Spacing.medium) {
                if !state.isError {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(state.title)
                        .foregroundStyle(state.isError ? Tone.error : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        detailLine(state.detail, fullWidth: true)
                        detailLine(state.compactDetail, fullWidth: false)
                    }
                    if let progress = state.progress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let setUpAgain = state.setUpAgainTitle {
                    Button(setUpAgain) { confirmingSetUpAgain = true }
                        .buttonStyle(.kitSecondary)
                }
                if let retry = state.retryTitle {
                    Button(retry, action: onRetry).buttonStyle(.kitPrimary)
                }
            }
            if state == .checking {
                // The skeleton row of mockup section 4: a placeholder line.
                Text(HubAdoptionState.movingTitle)
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(HubAdoptionState.setUpAgainQuestion, isPresented: $confirmingSetUpAgain) {
            Button(HubAdoptionState.setUpAgainConfirmTitle, role: .destructive, action: onSetUpAgain)
            Button(HubAdoptionState.cancelTitle, role: .cancel) {}
        } message: {
            Text(HubAdoptionState.setUpAgainMessage)
        }
    }

    /// The caption: on one line while it fits, else the compact text wrapped.
    @ViewBuilder
    private func detailLine(_ text: String?, fullWidth: Bool) -> some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(fullWidth ? 1 : nil)
                .fixedSize(horizontal: fullWidth, vertical: !fullWidth)
        }
    }
}
