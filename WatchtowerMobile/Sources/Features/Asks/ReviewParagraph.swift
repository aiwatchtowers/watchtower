import Foundation
import WatchtowerKit

/// One line of a review snapshot as the page draws it (#1787): the
/// document reads in the screen's own scroll, one `Text` per line, and a
/// long press on a line comments on it. `range` is the line's text after
/// its list marker, in UTF-16 units of `document.text`, so a comment on it
/// is an anchor `CommentAnchorBuilder` takes; `extent` is the whole line
/// (marker included), which places a comment made on any part of it.
struct ReviewParagraph: Equatable, Identifiable {
    /// The line's start in `document.text`.
    let id: Int
    let extent: NSRange
    let range: NSRange
    /// The line's text after its marker.
    let text: String
    /// "• ", "  1. ", "☐ ": drawn in its own column so wrapped text hangs.
    let marker: String?
    /// 1, 2, 3+ for a heading line; nil for body text.
    let headingLevel: Int?

    /// The non-blank lines of `document` (blank lines and a rule's lone
    /// no-break space are spacing, not paragraphs), in order. Headings come
    /// from `document.headings` by their offset.
    static func split(_ document: PlainTextDocument) -> [Self] {
        let text = document.text as NSString
        let levels = Dictionary(document.headings.map { ($0.offset, $0.level) }) { first, _ in first }
        var out: [Self] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, extent, _, _ in
            guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let level = levels[extent.location]
            let marker = level == nil ? listPrefix(of: line) : nil
            let skip = (marker as NSString?)?.length ?? 0
            let range = NSRange(location: extent.location + skip, length: extent.length - skip)
            out.append(Self(
                id: extent.location, extent: extent, range: range,
                text: text.substring(with: range), marker: marker, headingLevel: level
            ))
        }
        return out
    }

    /// The paragraph whose line holds `location`; nil past the text or on a
    /// blank line. `paragraphs` in document order.
    static func index(of location: Int, in paragraphs: [Self]) -> Int? {
        var low = 0
        var high = paragraphs.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let extent = paragraphs[mid].extent
            if location < extent.location {
                high = mid - 1
            } else if location >= NSMaxRange(extent) {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// The marker a list line starts with, its leading spaces included:
    /// "• ", "N. ", "☐ " or "☑ "; nil for any other line.
    static func listPrefix(of line: String) -> String? {
        let indent = String(line.prefix { $0 == " " })
        let rest = line.dropFirst(indent.count)
        if let marker = ["• ", "☐ ", "☑ "].first(where: { rest.hasPrefix($0) }) {
            return indent + marker
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return indent + digits + ". "
    }
}
