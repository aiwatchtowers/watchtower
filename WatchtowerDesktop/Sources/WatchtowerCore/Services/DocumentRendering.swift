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
        return RenderedDocument(text: out.text, headings: out.headings, runs: out.runs)
    }

    private static func render(_ block: MarkdownBlock, into out: inout Builder, depth: Int) {
        switch block {
        case let .heading(level, inlines):
            out.headings.append(DocumentHeading(offset: out.length, level: level, title: plain(inlines)))
            out.styled(.heading(level)) { render(inlines, into: &$0) }
        case let .paragraph(inlines):
            render(inlines, into: &out)
        case let .code(_, code):
            out.styled(.codeBlock) { $0.append(code) }
        case let .list(list):
            render(list, into: &out, depth: depth)
        case let .quote(children):
            out.styled(.quote) { quoted in
                for child in children { render(child, into: &quoted, depth: depth) }
            }
        case let .table(table):
            render(table, into: &out)
        case .rule:
            out.append("———")
        }
        out.endBlock()
    }

    private static func render(_ list: MarkdownList, into out: inout Builder, depth: Int) {
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
                case let .paragraph(inlines): render(inlines, into: &out)
                case let .list(nested): render(nested, into: &out, depth: depth + 1)
                default: render(block, into: &out, depth: depth + 1)
                }
            }
            out.newlineIfNeeded()
        }
    }

    private static func render(_ table: MarkdownTable, into out: inout Builder) {
        let rows = [table.header] + table.rows
        for (index, row) in rows.enumerated() {
            if index > 0 { out.append("\n") }
            out.append(row.map(plain).joined(separator: " | "))
        }
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
