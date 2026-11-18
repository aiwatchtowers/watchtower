#if os(iOS)
import SwiftUI

/// The phone has no selection chip over the feed; its answers offer "Ask about this" on the row, which opens the
/// passage picker.
struct ChatFeedQuoteSupport: ViewModifier {
    let onQuote: ((String) -> Void)?

    func body(content: Content) -> some View {
        content
    }
}

/// "Ask about this" under an answer: the passage picker sheet; the picked passage goes to the composer's quotes.
struct ChatQuoteRowAction: View {
    let text: String
    let onQuote: (String) -> Void
    @State private var picking = false
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        style.secondaryButton(PassagePickerSheet.askLabel) { picking = true }
            .accessibilityIdentifier("chat.message.quote")
            .sheet(isPresented: $picking) {
                PassagePickerSheet(text: text, pick: onQuote)
            }
    }
}
#endif
