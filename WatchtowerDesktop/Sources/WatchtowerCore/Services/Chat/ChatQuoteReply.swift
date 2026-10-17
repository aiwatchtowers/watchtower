import Foundation

/// One quoted passage of an assistant answer waiting in the composer's
/// batch, with the owner's (optional, editable) comment.
package struct ChatQuoteDraft: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let quote: String
    package var comment: String

    package init(quote: String, comment: String, id: UUID = UUID()) {
        self.id = id
        self.quote = quote
        self.comment = comment
    }
}

/// Quoting a passage selected in the main chat's feed into the reply batch
/// ("Ask about this"). Pure.
package enum ChatQuoteReply {
    package static let batchHeader = "About these parts of your answers:"

    /// The selected span of `text` (a UTF-16 `NSRange`, as `NSTextView`
    /// reports it); nil when nothing but whitespace is selected.
    package static func selectedText(_ text: String, selection: NSRange) -> String? {
        guard selection.length > 0, let range = Range(selection, in: text) else { return nil }
        let quote = String(text[range])
        return quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : quote
    }

    /// The one owner message for a send: every pending quote (in the order
    /// added), then the owner's typed text. nil = nothing to send.
    package static func compose(quotes: [ChatQuoteDraft], typed: String) -> String? {
        CommentBatchComposer.compose(
            header: batchHeader,
            items: quotes.map { CommentBatchComposer.Item(quote: $0.quote, heading: "", comment: $0.comment) },
            note: typed
        )
    }
}
