import SwiftUI

/// What the composer may do now.
enum ComposerMode: Equatable {
    /// The owner can write; while the agent works the line queues.
    case message
    /// A permission prompt or an ask waits above: the field points at it.
    case answerAbove
    /// Typing is not possible; the reason is the placeholder ("Typing is
    /// off in Settings").
    case unavailable(String)
}

/// The composer's visible state: the placeholder, whether the field takes
/// text, and whether Send is live (text to send, not already sending).
struct ComposerBarModel: Equatable {
    let placeholder: String
    let isFieldEnabled: Bool
    let canSend: Bool

    init(text: String, mode: ComposerMode, isSending: Bool = false) {
        switch mode {
        case .message:
            placeholder = "Message the session…"
            isFieldEnabled = true
        case .answerAbove:
            placeholder = "Answer the request above"
            isFieldEnabled = false
        case let .unavailable(reason):
            placeholder = reason
            isFieldEnabled = false
        }
        canSend = isFieldEnabled && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The Workchat's composer at the foot of the screen, the Desktop's
/// `WorkchatComposer` at phone size (mockups 3, 4, 8): a hairline on top, a
/// `Fill.card` field with a hairline at `Radius.pill`, growing to five
/// lines, and a round Send (accent when live, on the card fill when not)
/// in a 44 pt hit area; an optional `note` under it. Goes in
/// `.safeAreaInset(edge: .bottom, spacing: 0)`.
///
///     WorkchatComposerBar(text: $draft, mode: .message, isSending: model.isSending) { send() }
struct WorkchatComposerBar: View {
    @Binding var text: String
    let mode: ComposerMode
    var isSending = false
    var note: String?
    let onSend: () -> Void

    var body: some View {
        let model = ComposerBarModel(text: text, mode: mode, isSending: isSending)
        let field = RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .bottom, spacing: Spacing.small) {
                TextField(model.placeholder, text: $text, axis: .vertical)
                    .font(TypeScale.rowTitle)
                    .lineLimit(1...5)
                    .disabled(!model.isFieldEnabled)
                    .padding(.vertical, Spacing.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            model.canSend ? Color.white : Color.secondary,
                            model.canSend ? Color.accentColor : Fill.card
                        )
                        .frame(minWidth: PhoneMetrics.minTouch, minHeight: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
            }
            .padding(.leading, Spacing.medium)
            .background(Fill.card, in: field)
            .overlay(field.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .background(alignment: .top) {
            Divider()
        }
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .bottom)
    }
}
