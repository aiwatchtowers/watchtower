import Foundation
import WatchtowerChatText

/// Parsed markdown per feed entry, so a re-render of a long chat does not
/// re-parse every message. Keyed by entry id; a changed text (a streaming
/// entry that grew) or line-break mode re-parses that entry only. An owner
/// line's images (`WorkchatOwnerImages.split`) are kept the same way: its
/// shown text and its bubble's images come from one split.
@MainActor
package final class SessionFeedMarkdownCache {
    private struct Slot {
        let text: String
        let lineBreaks: Bool
        let blocks: [MarkdownBlock]
    }

    private var slots: [String: Slot] = [:]
    package private(set) var parseCount = 0

    private struct OwnerSlot {
        let text: String
        let attachmentsRoot: String?
        let split: WorkchatOwnerImages
    }

    private var ownerSlots: [String: OwnerSlot] = [:]
    package private(set) var splitCount = 0

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

    /// An owner line's text split from its images, once per id and text.
    package func ownerImages(id: String, text: String, attachmentsRoot: String?) -> WorkchatOwnerImages {
        if let slot = ownerSlots[id], slot.text == text, slot.attachmentsRoot == attachmentsRoot { return slot.split }
        splitCount += 1
        let split = WorkchatOwnerImages.split(text, attachmentsRoot: attachmentsRoot)
        ownerSlots[id] = OwnerSlot(text: text, attachmentsRoot: attachmentsRoot, split: split)
        return split
    }
}
