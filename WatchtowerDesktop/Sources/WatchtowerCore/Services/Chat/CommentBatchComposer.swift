import Foundation

/// The owner's comments go to the assistant as ONE batch, never one by one
/// (owner rule, every surface): artifact comments ("Send N comments", Task 24)
/// and chat quotes (the pending quote batch, Task 25) both compose their
/// single owner message here. Pure.
package enum CommentBatchComposer {
    /// One quoted passage and the owner's comment on it.
    package struct Item: Equatable, Sendable {
        package let quote: String
        /// The nearest heading above the quote ("" = none).
        package let heading: String
        package let comment: String

        package init(quote: String, heading: String, comment: String) {
            self.quote = quote
            self.heading = heading
            self.comment = comment
        }
    }

    /// `header`, the numbered items, `closing`, then the owner's own `note`,
    /// separated by blank lines. With no items only the note remains (header
    /// and closing describe items); nil when there is nothing at all.
    package static func compose(header: String?, items: [Item], closing: String? = nil, note: String = "") -> String? {
        var blocks: [String] = []
        if !items.isEmpty {
            if let header { blocks.append(header) }
            for (index, item) in items.enumerated() {
                let place = item.heading.isEmpty ? "On this passage:" : "Under \"\(item.heading)\":"
                var lines = ["\(index + 1). \(place)", blockquote(item.quote)]
                let comment = item.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !comment.isEmpty { lines.append(comment) }
                blocks.append(lines.joined(separator: "\n"))
            }
            if let closing { blocks.append(closing) }
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { blocks.append(trimmedNote) }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// `text` as one markdown blockquote: surrounding whitespace trimmed,
    /// every line prefixed with "> ", a blank line kept as ">" so the quote
    /// stays a single block. A line's own indentation is kept.
    package static func blockquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let kept = String(line.reversed().drop(while: \.isWhitespace).reversed())
                return kept.isEmpty ? ">" : "> " + kept
            }
            .joined(separator: "\n")
    }

    package static func sendButtonTitle(count: Int) -> String {
        count == 1 ? "Send 1 comment" : "Send \(count) comments"
    }
}
