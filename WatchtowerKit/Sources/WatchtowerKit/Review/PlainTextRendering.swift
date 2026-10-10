import Foundation

/// A review ask's `doc_snapshot` rendered to the plain text its comments
/// anchor on, with the headings' UTF-16 offsets into it: the phone's twin
/// of Core's `RenderedDocument` (text and headings only, no style runs).
public struct PlainTextDocument: Equatable, Sendable {
    public struct Heading: Equatable, Sendable {
        /// UTF-16 offset of the heading's first character in `text`.
        public let offset: Int
        public let level: Int
        public let title: String

        public init(offset: Int, level: Int, title: String) {
            self.offset = offset
            self.level = level
            self.title = title
        }
    }

    public let text: String
    public let headings: [Heading]

    public init(text: String, headings: [Heading]) {
        self.text = text
        self.headings = headings
    }
}

/// Markdown → the plain text Core's `DocumentRendering.render` gives (mobile
/// POC spec §6.2), so an anchor the phone takes is one the Mac finds again.
/// A port of its text rules over a small CommonMark + GFM reader, as Core
/// reads swift-markdown's tree: every block ends with one blank line; a
/// heading or paragraph is its inline text (markup dropped, soft breaks a
/// space, hard breaks a newline); a code block is its code; a list item
/// starts with its indent and "• ", "N. ", "☑ " or "☐ "; a quote is its
/// children; a table puts every cell on its own line, then a blank line; a
/// rule is one no-break space.
///
/// Limits (the Mac re-validates and re-locates every anchor, whitespace
/// runs read as one space): link reference definitions and reference links
/// stay literal, and raw HTML is kept as text.
public enum PlainTextRendering {
    public static func render(_ markdown: String) -> PlainTextDocument {
        var out = PlainTextBuilder()
        for block in MarkdownBlockReader.read(markdown) {
            render(block, into: &out, depth: 0)
        }
        return PlainTextDocument(text: out.text, headings: out.headings)
    }

    private static func render(_ block: MarkdownBlock, into out: inout PlainTextBuilder, depth: Int) {
        switch block {
        case let .heading(level, title):
            out.headings.append(.init(offset: out.length, level: level, title: title))
            out.append(title)
        case let .paragraph(text), let .code(text):
            out.append(text)
        case let .list(list):
            render(list, into: &out, depth: depth)
        case let .quote(children):
            for child in children { render(child, into: &out, depth: depth) }
        case let .table(rows):
            render(table: rows, into: &out)
        case .rule:
            out.append("\u{00A0}")
        }
        out.endBlock()
    }

    private static func render(_ list: MarkdownList, into out: inout PlainTextBuilder, depth: Int) {
        let indent = String(repeating: "    ", count: depth)
        for (index, item) in list.items.enumerated() {
            let marker: String = switch item.task {
            case .checked: "☑ "
            case .unchecked: "☐ "
            case .none: list.ordered ? "\(list.start + index). " : "• "
            }
            out.append(indent + marker)
            for (position, block) in item.blocks.enumerated() {
                if position > 0 { out.newlineIfNeeded() }
                switch block {
                case let .paragraph(text): out.append(text)
                case let .list(nested): render(nested, into: &out, depth: depth + 1)
                default: render(block, into: &out, depth: depth + 1)
                }
            }
            out.newlineIfNeeded()
        }
    }

    private static func render(table rows: [[String]], into out: inout PlainTextBuilder) {
        let columns = rows.map(\.count).max() ?? 0
        out.newlineIfNeeded()
        for row in rows {
            for column in 0..<columns {
                if column < row.count { out.append(row[column]) }
                out.append("\n")
            }
        }
        out.append("\n")
    }
}

private struct PlainTextBuilder {
    var text = ""
    /// UTF-16 length of `text`.
    var length = 0
    var headings: [PlainTextDocument.Heading] = []

    mutating func append(_ value: String) {
        text += value
        length += value.utf16.count
    }

    mutating func newlineIfNeeded() {
        if !text.isEmpty, !text.hasSuffix("\n") { append("\n") }
    }

    /// Every block ends with one blank line.
    mutating func endBlock() {
        guard !text.isEmpty, !text.hasSuffix("\n\n") else { return }
        append(text.hasSuffix("\n") ? "\n" : "\n\n")
    }
}
