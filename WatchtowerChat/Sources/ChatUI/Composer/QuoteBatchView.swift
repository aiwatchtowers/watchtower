import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The pending quote batch above the composer: each quote with its editable comment and a remove button
/// (`ChatUIStyle.quoteRow`). It never sends — the composer's send takes the whole batch as one message.
public struct QuoteBatchView: View {
    let quotes: [ChatQuoteDraft]
    let onEditComment: (UUID, String) -> Void
    let onRemove: (UUID) -> Void
    @Environment(\.chatUIStyle) private var style

    public init(
        quotes: [ChatQuoteDraft],
        onEditComment: @escaping (UUID, String) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        self.quotes = quotes
        self.onEditComment = onEditComment
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(quotes) { quote in
                style.quoteRow(
                    quote,
                    comment: Binding(get: { quote.comment }, set: { onEditComment(quote.id, $0) })
                ) { onRemove(quote.id) }
            }
        }
        .padding(.horizontal, ComposerMetrics.quoteInset)
    }
}
