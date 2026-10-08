import Foundation

/// A review comment's anchor on the rendered snapshot (mobile POC spec
/// §6.2): a port of Core's `CommentAnchor.make`. The selected quote, up to
/// `contextLength` characters (graphemes) on either side, and the nearest
/// heading at or before the selection. The Mac re-locates it on its own
/// rendering of the same snapshot; the shared `anchor-fixtures.json` pins
/// both sides.
public enum CommentAnchorBuilder {
    public static let contextLength = 64

    public struct Anchor: Hashable, Sendable {
        public let quote: String
        public let prefix: String
        public let suffix: String
        public let heading: String

        public init(quote: String, prefix: String, suffix: String, heading: String) {
            self.quote = quote
            self.prefix = prefix
            self.suffix = suffix
            self.heading = heading
        }
    }

    /// The anchor of `selection` (UTF-16 units into `document.text`); nil
    /// for an empty selection or one past the text.
    public static func anchor(selection: NSRange, in document: PlainTextDocument) -> Anchor? {
        guard selection.length > 0, let range = Range(selection, in: document.text) else { return nil }
        return make(text: document.text, range: range, headings: document.headings)
    }

    public static func make(text: String, range: Range<String.Index>, headings: [PlainTextDocument.Heading]) -> Anchor {
        let start = text.index(range.lowerBound, offsetBy: -contextLength, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: contextLength, limitedBy: text.endIndex) ?? text.endIndex
        let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let heading = headings.filter { $0.offset <= offset }.max { $0.offset < $1.offset }?.title ?? ""
        return Anchor(
            quote: String(text[range]),
            prefix: String(text[start..<range.lowerBound]),
            suffix: String(text[range.upperBound..<end]),
            heading: heading
        )
    }
}

extension OwnerAskAnswer.Comment {
    /// A comment on `anchor` with the owner's text.
    public init(anchor: CommentAnchorBuilder.Anchor, body: String) {
        self.init(quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, heading: anchor.heading, body: body)
    }
}
