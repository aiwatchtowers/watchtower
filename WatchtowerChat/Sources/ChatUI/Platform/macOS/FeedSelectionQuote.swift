#if os(macOS)
import SwiftUI

/// The Mac's "Ask about this" on the shared feed (D10): with quoting on, finished answers mark their body
/// (`chatAnswerRegions`, read by `ChatAnswerText`) and the floating chip over the feed quotes a selection in one.
struct ChatFeedQuoteSupport: ViewModifier {
    let onQuote: ((String) -> Void)?
    @State private var tracker = ChatSelectionQuoteTracker()

    func body(content: Content) -> some View {
        content
            .environment(\.chatAnswerRegions, onQuote == nil ? nil : tracker)
            .overlay {
                if let onQuote {
                    ChatSelectionQuoteOverlay(tracker: tracker, quote: ChatFeedSelectionQuote(onQuote: onQuote))
                }
            }
    }
}

/// The Mac quotes by selecting in the feed; a row has no Quote button.
struct ChatQuoteRowAction: View {
    let text: String
    let onQuote: (String) -> Void

    var body: some View {
        EmptyView()
    }
}
#endif
