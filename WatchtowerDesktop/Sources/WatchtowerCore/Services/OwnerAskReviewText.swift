import Foundation

/// Where a review's focus items and margin comments sit in the ask's
/// rendered `doc_snapshot` (spec 2026-10-03 Parts 8 and 10). Every range is
/// taken on the snapshot the agent filed, never on the live file: a later
/// edit is a new ask. Pure.
package enum OwnerAskReviewText {
    /// A focus item's place: its `quote` — as written, or as the Markdown
    /// renders it, whitespace runs read as one space — else its `heading`'s
    /// title. nil when it names neither or the snapshot has no such place;
    /// the header then lists it without a link.
    package static func range(of focus: OwnerAskFocus, in doc: RenderedDocument) -> NSRange? {
        quoteRange(focus.quote, in: doc) ?? headingRange(focus.heading, in: doc)
    }

    /// The anchor of a margin comment on `selection` of the rendered
    /// snapshot; nil for an empty selection or one past the text.
    package static func anchor(selection: NSRange, in doc: RenderedDocument) -> CommentAnchor? {
        guard selection.length > 0, let range = Range(selection, in: doc.text) else { return nil }
        return CommentAnchor.make(text: doc.text, range: range, headings: doc.headingOffsets)
    }

    /// A stored comment's anchor, for a closed ask's read-only margin.
    package static func anchor(of comment: OwnerAskAnswer.Comment) -> CommentAnchor {
        CommentAnchor(quote: comment.quote, prefix: comment.prefix, suffix: comment.suffix, heading: comment.heading)
    }

    package static func range(of anchor: CommentAnchor, in doc: RenderedDocument) -> NSRange? {
        anchor.locate(in: doc.text).map { NSRange($0, in: doc.text) }
    }

    private static func quoteRange(_ quote: String, in doc: RenderedDocument) -> NSRange? {
        let written = trimmed(quote)
        guard !written.isEmpty else { return nil }
        let rendered = trimmed(DocumentRendering.render(written).text)
        let text = doc.text as NSString
        for needle in [written, rendered] where !needle.isEmpty {
            let hit = text.range(of: needle)
            if hit.location != NSNotFound { return hit }
        }
        for needle in [written, rendered] where !needle.isEmpty {
            if let hit = range(of: CommentAnchor(quote: needle, prefix: "", suffix: "", heading: ""), in: doc) { return hit }
        }
        return nil
    }

    /// The first heading whose title matches, the Markdown hashes, case and
    /// spacing aside.
    private static func headingRange(_ heading: String, in doc: RenderedDocument) -> NSRange? {
        let wanted = normalized(String(trimmed(heading).drop { $0 == "#" }))
        guard !wanted.isEmpty,
              let match = doc.headings.first(where: { normalized($0.title) == wanted }) else { return nil }
        return NSRange(location: match.offset, length: match.title.utf16.count)
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
