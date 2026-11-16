import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// A failed or cut reply (the `error` part): the phrase for its code, the session's own text under it, and Retry when a
/// retry can help (`ChatErrorText`, shared with Go's fallback). A cut reply (`partial`, not the quota) offers Continue.
struct ErrorPartView: View {
    static let retryLabel = "Retry"
    static let continueLabel = "Continue"
    static let reviewActionsLabel = "Review actions"

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
                    if ChatErrorText.isRetryable(payload.code), context.actions.canRetry?(context.message.id) ?? true {
                        style.secondaryButton(Self.retryLabel) { context.actions.retry(context.message.id) }
                            .accessibilityIdentifier("chat.error.retry")
                    }
                    if context.message.status == ChatMessageStatus.partial, payload.code != "quota_exhausted",
                       context.actions.offersContinue {
                        style.secondaryButton(Self.continueLabel) { context.actions.continueStopped(context.message.id) }
                    }
                    if payload.code == "quota_exhausted", let review = context.actions.reviewActions {
                        style.secondaryButton(Self.reviewActionsLabel) { review(context.message.id) }
                    }
                }
            }
        }
        .accessibilityIdentifier("chat.error")
    }
}
