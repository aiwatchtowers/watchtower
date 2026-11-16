#if os(iOS)
import SwiftUI
import WatchtowerDesign

/// The phone's composer field: a growing text field; the caret is taken as the end of the text (the `@` picker reads
/// the query before it).
struct ChatComposerTextInput: View {
    @Binding var text: String
    @Binding var cursor: Int
    let placeholder: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .font(.body)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.regular)
            .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.bubble))
            .onChange(of: text) { _, new in cursor = new.utf16.count }
            .accessibilityIdentifier("chat.composer.field")
    }
}
#endif

#if os(iOS)
/// The phone has no composer shortcuts (a hardware keyboard's Return sends through the field).
struct ChatComposerShortcuts: View {
    let canSend: Bool
    let canStop: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        EmptyView()
    }
}
#endif
