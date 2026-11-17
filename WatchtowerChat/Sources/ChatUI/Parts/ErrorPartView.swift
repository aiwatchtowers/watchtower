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

    private var retry: (() -> Void)? {
        guard ChatErrorText.isRetryable(payload.code), context.actions.canRetry?(context.message.id) ?? true else { return nil }
        return { context.actions.retry(context.message.id) }
    }

    private var continueStopped: (() -> Void)? {
        guard context.message.status == ChatMessageStatus.partial, payload.code != "quota_exhausted",
              context.actions.offersContinue else { return nil }
        return { context.actions.continueStopped(context.message.id) }
    }

    private var reviewActions: (() -> Void)? {
        guard payload.code == "quota_exhausted", let review = context.actions.reviewActions else { return nil }
        return { review(context.message.id) }
    }

    var body: some View {
        let content = ChatErrorCardContent(
            code: payload.code, message: ChatErrorText.message(for: payload.code, provider: context.provider),
            detail: ChatErrorText.detail(payload.message), retry: retry, continueStopped: continueStopped,
            reviewActions: reviewActions, replyHasText: !context.message.text.isEmpty
        )
        if let card = style.errorCard(content) {
            card.accessibilityIdentifier("chat.error")
        } else {
            ownCard
        }
    }

    private var ownCard: some View {
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
                    if let retry {
                        style.secondaryButton(Self.retryLabel, action: retry)
                            .accessibilityIdentifier("chat.error.retry")
                    }
                    if let continueStopped {
                        style.secondaryButton(Self.continueLabel, action: continueStopped)
                    }
                    if let reviewActions {
                        style.secondaryButton(Self.reviewActionsLabel, action: reviewActions)
                    }
                }
            }
        }
        .accessibilityIdentifier("chat.error")
    }
}
