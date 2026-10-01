import AppKit
import WatchtowerCore

/// Rendered text → `NSAttributedString`, laid out the way the chat's
/// `MarkdownView` reads it: fonts per style run, lists hanging under their
/// markers, code blocks and quotes as boxes, tables as real tables (TextKit 1
/// `NSTextTable`, which `DocumentTextView` is built on), a rule as a line.
/// Then a yellow background on every anchored thread (stronger on the
/// active one) and a blue one on every unsent draft comment.
enum DocumentAttributedString {
    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.25)
    static let activeHighlight = NSColor.systemYellow.withAlphaComponent(0.55)
    static let draftHighlight = NSColor.systemBlue.withAlphaComponent(0.2)

    static func make(
        _ doc: RenderedDocument,
        highlights: [Int64: NSRange],
        activeThreadID: Int64?,
        drafts: [NSRange] = []
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: doc.text,
            attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        )
        var layout = ParagraphLayout(string: doc.text as NSString)
        let length = out.length
        // Outer runs first, so a nested style wins (bold in a heading keeps
        // the heading size, a nested list item its own indent).
        let runs = doc.runs.enumerated()
            .filter { $0.element.location + $0.element.length <= length }
            .sorted { $0.element.length != $1.element.length ? $0.element.length > $1.element.length : $0.offset < $1.offset }
            .map(\.element)
        for run in runs {
            apply(run, to: out, layout: &layout)
        }
        layout.commit(to: out)
        for (id, range) in highlights where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: id == activeThreadID ? activeHighlight : highlight, range: range)
        }
        for range in drafts where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: draftHighlight, range: range)
        }
        return out
    }

    private static func apply(_ run: DocumentStyleRun, to out: NSMutableAttributedString, layout: inout ParagraphLayout) {
        let range = NSRange(location: run.location, length: run.length)
        switch run.style {
        case let .heading(level):
            out.addAttribute(.font, value: NSFont.systemFont(ofSize: headingSize(level), weight: .bold), range: range)
        case .strong:
            convertFonts(in: out, range: range, trait: .boldFontMask)
        case .emphasis:
            convertFonts(in: out, range: range, trait: .italicFontMask)
        case .strikethrough:
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .code:
            out.addAttributes([.font: codeFont, .backgroundColor: NSColor.quaternaryLabelColor], range: range)
        case .link:
            // Styled only: a click selects text for commenting, it never opens
            // a URL from a document the agent wrote.
            out.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .codeBlock, .quote, .listItem, .tableCell, .rule:
            applyBlock(run, to: out, layout: &layout)
        }
    }

    /// The paragraph-level styles: boxes, hanging indents, table cells.
    private static func applyBlock(_ run: DocumentStyleRun, to out: NSMutableAttributedString, layout: inout ParagraphLayout) {
        let range = NSRange(location: run.location, length: run.length)
        switch run.style {
        case .codeBlock:
            out.addAttribute(.font, value: codeFont, range: range)
            let block = box(padding: 8)
            block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
            layout.edit(range) { _, style in style.textBlocks.append(block) }
        case .quote:
            out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            let block = box(padding: 2)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.4), for: .minX)
            layout.edit(range) { _, style in style.textBlocks.append(block) }
        case let .listItem(marker):
            let prefix = (out.string as NSString).substring(with: NSRange(location: run.location, length: min(marker, run.length)))
            let indent = ceil((prefix as NSString).size(withAttributes: [.font: bodyFont]).width)
            layout.edit(range) { paragraph, style in
                style.headIndent = indent
                style.firstLineHeadIndent = paragraph.location == run.location ? 0 : indent
            }
        case let .tableCell(cell):
            if cell.header { convertFonts(in: out, range: range, trait: .boldFontMask) }
            let block = NSTextTableBlock(table: layout.table(cell), startingRow: cell.row, rowSpan: 1,
                                         startingColumn: cell.column, columnSpan: 1)
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(NSColor.separatorColor)
            if cell.header { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05) }
            layout.edit(range) { _, style in
                style.textBlocks.append(block)
                style.alignment = switch cell.alignment {
                case .leading: .natural
                case .center: .center
                case .trailing: .right
                }
            }
        case .rule:
            let block = box(padding: 0)
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(NSColor.separatorColor, for: .maxY)
            layout.edit(range) { _, style in style.textBlocks.append(block) }
        case .heading, .strong, .emphasis, .strikethrough, .code, .link:
            break
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 18
        case 3: 16
        default: 14
        }
    }

    /// Adds `trait` to every font already in `range` (bold code stays
    /// monospaced, a bold word in a heading keeps the heading size).
    private static func convertFonts(in out: NSMutableAttributedString, range: NSRange, trait: NSFontTraitMask) {
        out.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? bodyFont
            out.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }

    private static func box(padding: CGFloat) -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(padding, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    /// Paragraph styles built up run by run (outer runs first), keyed by
    /// paragraph start, then written once.
    private struct ParagraphLayout {
        let string: NSString
        private var styles: [Int: NSMutableParagraphStyle] = [:]
        private var tables: [Int: NSTextTable] = [:]

        init(string: NSString) {
            self.string = string
        }

        /// Calls `body` with each paragraph `range` touches and its style.
        mutating func edit(_ range: NSRange, _ body: (NSRange, NSMutableParagraphStyle) -> Void) {
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                // swiftlint:disable:next force_cast
                let style = styles[paragraph.location] ?? NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                body(paragraph, style)
                styles[paragraph.location] = style
                location = NSMaxRange(paragraph)
            }
        }

        /// One `NSTextTable` per rendered table: every cell of it shares it.
        mutating func table(_ cell: DocumentTableCell) -> NSTextTable {
            if let table = tables[cell.table] { return table }
            let table = NSTextTable()
            table.numberOfColumns = cell.columns
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
            table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
            tables[cell.table] = table
            return table
        }

        func commit(to out: NSMutableAttributedString) {
            for (location, style) in styles {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                out.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        }
    }
}
