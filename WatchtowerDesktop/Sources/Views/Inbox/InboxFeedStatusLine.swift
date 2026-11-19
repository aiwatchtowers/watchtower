import SwiftUI
import WatchtowerCore
import WatchtowerInterface

/// The Inbox's line about its feed (mobile Inbox mockup §7): a spinner with
/// "Loading the Inbox…" or "Reconnecting to Watchtower…", or a failed read's
/// reason with Retry (Restart for another version). The words are the
/// model's (`InboxMacFeedStatus`); the colour is the warning tone.
struct InboxFeedStatusLine: View {
    let status: InboxMacFeedStatus
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            switch status.kind {
            case .loading, .reconnecting:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            }
            Text(status.text)
                .font(.callout)
                .foregroundStyle(status.kind == .failed ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let title = status.actionTitle {
                Button(title, action: onAction)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .background(status.kind == .failed ? Tone.warning.opacity(Fill.selectedOpacity) : .clear)
        .accessibilityIdentifier("inbox.feedStatus")
    }
}
