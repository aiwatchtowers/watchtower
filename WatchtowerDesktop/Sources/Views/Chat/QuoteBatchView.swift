import SwiftUI
import WatchtowerCore

/// The pending quote batch above the composer: each quote with its editable
/// comment and a remove button. It never sends — the composer's send takes
/// the whole batch as one message.
struct QuoteBatchView: View {
    let quotes: [ChatQuoteDraft]
    let onEditComment: (UUID, String) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(quotes) { quote in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\u{201C}\(quote.quote)\u{201D}")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        TextField("Comment (optional)", text: Binding(
                            get: { quote.comment },
                            set: { onEditComment(quote.id, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    }
                    Button { onRemove(quote.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove quote")
                        .accessibilityLabel("Remove quote")
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
    }
}
