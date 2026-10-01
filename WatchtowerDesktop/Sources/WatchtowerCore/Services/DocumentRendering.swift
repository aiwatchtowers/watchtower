import Foundation

package enum DocumentStyle: Equatable, Sendable {
    case heading(Int)
    case strong
    case emphasis
    case strikethrough
    case code
    case codeBlock
    case quote
    case link(String)
    /// One list item, from its marker through its last nested line;
    /// `marker` is the UTF-16 length of its indent + marker ("    • "), which
    /// the item's wrapped lines hang under.
    case listItem(marker: Int)
    /// One table cell's paragraph(s), its newline included.
    case tableCell(DocumentTableCell)
    /// A thematic break: a one-character paragraph drawn as a line.
    case rule
    /// A highlighted token inside a code block (`CodeHighlighter`).
    case codeToken(CodeToken.Kind)
}

/// Where a `.tableCell` run sits: which table of the document, its row
/// (0 = header row) and column, and the table's column count.
package struct DocumentTableCell: Equatable, Sendable {
    package let table: Int
    package let row: Int
    package let column: Int
    package let columns: Int
    package let alignment: MarkdownAlignment

    package var header: Bool { row == 0 }

    package init(table: Int, row: Int, column: Int, columns: Int, alignment: MarkdownAlignment) {
        self.table = table
        self.row = row
        self.column = column
        self.columns = columns
        self.alignment = alignment
    }
}

/// A styled span of `RenderedDocument.text`, in UTF-16 units (`NSRange`).
package struct DocumentStyleRun: Equatable, Sendable {
    package let location: Int
    package let length: Int
    package let style: DocumentStyle

    package init(location: Int, length: Int, style: DocumentStyle) {
        self.location = location
        self.length = length
        self.style = style
    }
}

package struct DocumentHeading: Equatable, Sendable {
    /// UTF-16 offset of the heading's first character in the rendered text.
    package let offset: Int
    package let level: Int
    package let title: String

    package init(offset: Int, level: Int, title: String) {
        self.offset = offset
        self.level = level
        self.title = title
    }
}

/// A project document rendered to the plain text comments anchor on, plus
/// the style runs the app turns into an `NSAttributedString`.
package struct RenderedDocument: Equatable, Sendable {
    package let text: String
    package let headings: [DocumentHeading]
    package let runs: [DocumentStyleRun]

    /// The shape `CommentAnchor.make` takes.
    package var headingOffsets: [(offset: Int, title: String)] {
        headings.map { ($0.offset, $0.title) }
    }
}

/// Markdown → plain text + runs, over the chat's swift-markdown model
/// (`MarkdownDocument`). Deterministic: the same markdown always renders the
/// same text, which is what keeps an unchanged file's anchors valid.
package enum DocumentRendering {
    package static func render(_ markdown: String) -> RenderedDocument {
        var out = Builder()
        for block in MarkdownDocument.parse(markdown) {
            render(block, into: &out, depth: 0)
        }
        return out.document
    }

    /// A `table` artifact's CSV rows (the first is the header) as a table.
    /// Only the empty records a trailing newline leaves at the end are
    /// dropped; an empty record inside the data stays an empty row.
    package static func renderTable(rows: [[String]]) -> RenderedDocument {
        var rows = rows
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        var out = Builder()
        if let header = rows.first {
            let cells = { (row: [String]) in row.map { [MarkdownInline.text($0)] } }
            render(MarkdownTable(header: cells(header), rows: rows.dropFirst().map(cells), alignments: []), into: &out)
        }
        return out.document
    }

    /// A `code` artifact: one code block, highlighted for `language`.
    package static func renderCode(_ code: String, language: String?) -> RenderedDocument {
        var out = Builder()
        appendCode(code, language: language, into: &out)
        return out.document
    }

    private static func render(_ block: MarkdownBlock, into out: inout Builder, depth: Int) {
        switch block {
        case let .heading(level, inlines):
            out.headings.append(DocumentHeading(offset: out.length, level: level, title: plain(inlines)))
            out.styled(.heading(level)) { render(inlines, into: &$0) }
        case let .paragraph(inlines):
            render(inlines, into: &out)
        case let .code(language, code):
            appendCode(code, language: language, into: &out)
        case let .list(list):
            render(list, into: &out, depth: depth)
        case let .quote(children):
            out.styled(.quote) { quoted in
                for child in children { render(child, into: &quoted, depth: depth) }
            }
        case let .table(table):
            render(table, into: &out)
        case .rule:
            out.styled(.rule) { $0.append("\u{00A0}") }
        }
        out.endBlock()
    }

    private static func appendCode(_ code: String, language: String?, into out: inout Builder) {
        out.styled(.codeBlock) { out in
            for token in CodeHighlighter.tokens(code, language: language) {
                if token.kind == .plain {
                    out.append(token.text)
                } else {
                    out.styled(.codeToken(token.kind)) { $0.append(token.text) }
                }
            }
        }
    }

    private static func render(_ list: MarkdownList, into out: inout Builder, depth: Int) {
        let indent = String(repeating: "    ", count: depth)
        for (index, item) in list.items.enumerated() {
            let marker: String = switch item.task {
            case .checked: "☑ "
            case .unchecked: "☐ "
            case .none: list.ordered ? "\(list.start + index). " : "• "
            }
            let prefix = indent + marker
            out.styled(.listItem(marker: prefix.utf16.count)) { out in
                out.append(prefix)
                for (position, block) in item.blocks.enumerated() {
                    if position > 0 { out.newlineIfNeeded() }
                    switch block {
                    case let .paragraph(inlines): render(inlines, into: &out)
                    case let .list(nested): render(nested, into: &out, depth: depth + 1)
                    default: render(block, into: &out, depth: depth + 1)
                    }
                }
                out.newlineIfNeeded()
            }
        }
    }

    /// Every cell is its own paragraph (a short row is padded with empty
    /// ones), so the app can lay the cells out as a real table; a blank
    /// line outside the table follows it.
    private static func render(_ table: MarkdownTable, into out: inout Builder) {
        let rows = [table.header] + table.rows
        let columns = rows.map(\.count).max() ?? 0
        let id = out.nextTableID
        out.nextTableID += 1
        out.newlineIfNeeded()
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                let alignment = column < table.alignments.count ? table.alignments[column] : .leading
                let cell = DocumentTableCell(table: id, row: rowIndex, column: column, columns: columns, alignment: alignment)
                out.styled(.tableCell(cell)) { out in
                    if column < row.count { render(row[column], into: &out) }
                    out.append("\n")
                }
            }
        }
        out.append("\n")
    }

    private static func render(_ inlines: [MarkdownInline], into out: inout Builder) {
        for inline in inlines {
            switch inline {
            case let .text(value): out.append(value)
            case let .code(value): out.styled(.code) { $0.append(value) }
            case let .emphasis(children): out.styled(.emphasis) { render(children, into: &$0) }
            case let .strong(children): out.styled(.strong) { render(children, into: &$0) }
            case let .strikethrough(children): out.styled(.strikethrough) { render(children, into: &$0) }
            case let .link(destination, children): out.styled(.link(destination)) { render(children, into: &$0) }
            case .lineBreak: out.append("\n")
            case .softBreak: out.append(" ")
            }
        }
    }

    private static func plain(_ inlines: [MarkdownInline]) -> String {
        var out = Builder()
        render(inlines, into: &out)
        return out.text
    }

    private struct Builder {
        var text = ""
        /// UTF-16 length of `text`, kept incrementally (O(1) per append).
        var length = 0
        var headings: [DocumentHeading] = []
        var runs: [DocumentStyleRun] = []
        var nextTableID = 0

        var document: RenderedDocument {
            RenderedDocument(text: text, headings: headings, runs: runs)
        }

        mutating func append(_ value: String) {
            text += value
            length += value.utf16.count
        }

        mutating func styled(_ style: DocumentStyle, _ body: (inout Self) -> Void) {
            let start = length
            body(&self)
            if length > start {
                runs.append(DocumentStyleRun(location: start, length: length - start, style: style))
            }
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
}
