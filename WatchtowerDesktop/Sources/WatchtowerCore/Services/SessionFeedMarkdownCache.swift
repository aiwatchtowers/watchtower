import Foundation

/// Parsed markdown per feed entry, so a re-render of a long chat does not
/// re-parse every message. Keyed by entry id; a changed text (a streaming
/// entry that grew) or line-break mode re-parses that entry only.
@MainActor
package final class SessionFeedMarkdownCache {
    private struct Slot {
        let text: String
        let lineBreaks: Bool
        let blocks: [MarkdownBlock]
    }

    private var slots: [String: Slot] = [:]
    package private(set) var parseCount = 0

    package init() {}

    package func blocks(id: String, text: String, lineBreaks: Bool) -> [MarkdownBlock] {
        if let slot = slots[id], slot.text == text, slot.lineBreaks == lineBreaks {
            return slot.blocks
        }
        parseCount += 1
        let parsed = MarkdownDocument.parse(text)
        let blocks = lineBreaks ? MarkdownDocument.withLineBreaks(parsed) : parsed
        slots[id] = Slot(text: text, lineBreaks: lineBreaks, blocks: blocks)
        return blocks
    }
}
