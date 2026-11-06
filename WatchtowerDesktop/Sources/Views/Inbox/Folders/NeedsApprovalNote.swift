import SwiftUI
import WatchtowerCore

/// The one-line note at the top of Needs approval while it falls back to
/// native cards (off, stopped, last run failed), with its press and the
/// reason a failed Turn On returned under it. No wiring (plan Task 1;
/// Task 12 hands in `onPress`).
struct NeedsApprovalNote: View {
    let content: NeedsApprovalNoteContent
    var onPress: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(content.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                if content.isApplying {
                    ProgressView().controlSize(.small)
                }
                Button(content.buttonTitle, action: onPress)
                    .buttonStyle(.kitSecondary)
                    .disabled(content.isApplying)
            }
            if let failure = content.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Fill.rest)
    }
}
