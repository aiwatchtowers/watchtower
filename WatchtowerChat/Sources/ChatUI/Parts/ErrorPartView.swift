import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// A failed or cut reply (the `error` part): the phrase for its code, the session's own text under it, and Retry when a
/// retry can help (`ChatErrorText`, shared with Go's fallback). A cut reply (`partial`, not the quota) offers Continue.
struct ErrorPartView: View {
    static let retryLabel = "Retry"
    static let continueLabel = "Continue"

    let payload: ChatErrorPayload
    let context: ChatPartContext
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        style.card {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label(ChatErrorText.message(for: payload.code, provider: context.provider),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Tone.error)
                if let detail = ChatErrorText.detail(payload.message) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: Spacing.regular) {
                    if ChatErrorText.isRetryable(payload.code) {
                        style.secondaryButton(Self.retryLabel) { context.actions.retry(context.message.id) }
                            .accessibilityIdentifier("chat.error.retry")
                    }
                    if context.message.status == ChatMessageStatus.partial, payload.code != "quota_exhausted" {
                        style.secondaryButton(Self.continueLabel) { context.actions.continueStopped(context.message.id) }
                    }
                }
            }
        }
        .accessibilityIdentifier("chat.error")
    }
}
