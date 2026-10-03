import AppKit
import WatchtowerCore

/// Rendered text → `NSAttributedString`, laid out the way the chat's
/// `MarkdownView` reads it: fonts per style run, lists hanging under their
/// markers, code blocks and quotes as boxes, tables as real tables (TextKit 1
/// `NSTextTable`, which `DocumentTextView` is built on), a rule as a line.
/// Then a yellow background on every anchored thread (stronger on the
/// active one) and a blue one on every unsent draft comment. Sizes and
/// rhythm come from a `DocumentTypography`: `.standard` for the comment
/// views, `ReviewTypography.style` for an owner ask's review body.
enum DocumentAttributedString {
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.25)
    static let activeHighlight = NSColor.systemYellow.withAlphaComponent(0.55)
    static let draftHighlight = NSColor.systemBlue.withAlphaComponent(0.2)

    /// The same inputs return the same instance: a paragraph style compares
    /// its text blocks and tables by identity, so two equal renders never
    /// compare equal, and `DocumentTextView` would otherwise re-lay the whole
    /// text out on every SwiftUI body pass (each resize frame included).
    @MainActor
    static func make(
        _ doc: RenderedDocument,
        highlights: [Int64: NSRange],
        activeThreadID: Int64?,
        drafts: [NSRange] = [],
        typography: DocumentTypography = .standard
    ) -> NSAttributedString {
        let key = Key(doc: doc, highlights: highlights, activeThreadID: activeThreadID, drafts: drafts, typography: typography)
        if let hit = recent.first(where: { $0.key == key }) { return hit.text }
        let text = build(key)
        recent = [(key, text)] + recent.prefix(recentLimit - 1)
        return text
    }

    private struct Key: Equatable {
        let doc: RenderedDocument
        let highlights: [Int64: NSRange]
        let activeThreadID: Int64?
        let drafts: [NSRange]
        let typography: DocumentTypography
    }

    /// A few documents may be on screen at once (a project document, an
    /// artifact panel, a quote sheet).
    private static let recentLimit = 4
    @MainActor private static var recent: [(key: Key, text: NSAttributedString)] = []

    private static func build(_ key: Key) -> NSAttributedString {
        let doc = key.doc
        let type = key.typography
        let out = NSMutableAttributedString(
            string: doc.text,
            attributes: [.font: type.bodyFont, .foregroundColor: NSColor.labelColor]
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
            apply(run, to: out, layout: &layout, typography: type)
        }
        layout.commit(to: out, typography: type)
        for (id, range) in key.highlights where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: id == key.activeThreadID ? activeHighlight : highlight, range: range)
        }
        for range in key.drafts where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: draftHighlight, range: range)
        }
        return out
    }

    private static func apply(
        _ run: DocumentStyleRun,
        to out: NSMutableAttributedString,
        layout: inout ParagraphLayout,
        typography type: DocumentTypography
    ) {
        let range = NSRange(location: run.location, length: run.length)
        switch run.style {
        case let .heading(level):
            out.addAttribute(.font, value: NSFont.systemFont(ofSize: type.headingSize(level), weight: .bold), range: range)
            layout.mark(range, .heading(level))
        case .strong:
            convertFonts(in: out, range: range, trait: .boldFontMask, typography: type)
        case .emphasis:
            convertFonts(in: out, range: range, trait: .italicFontMask, typography: type)
        case .strikethrough:
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .code:
            out.addAttributes([.font: type.codeFont, .backgroundColor: NSColor.quaternaryLabelColor], range: range)
        case let .link(destination):
            // Styled, with the destination on hover: a click selects text for
            // commenting, it never opens a URL from a document the agent wrote.
            out.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                               .toolTip: destination], range: range)
        case let .codeToken(kind):
            out.addAttribute(.foregroundColor, value: color(for: kind), range: range)
        case .codeBlock:
            out.addAttribute(.font, value: type.codeFont, range: range)
            layout.mark(range, .code)
            let block = box(padding: 8)
            block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
            layout.edit(range) { _, style in style.textBlocks.append(block) }
        case .quote:
            out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            layout.edit(range) { _, style in style.textBlocks.append(quoteBlock()) }
        case let .listItem(marker):
            applyListItem(run, marker: marker, to: out, layout: &layout, typography: type)
            layout.mark(range, .listItem)
        case let .tableCell(cell):
            applyTableCell(cell, range: range, to: out, layout: &layout, typography: type)
            layout.mark(range, .tableCell)
        case .rule:
            layout.mark(range, .rule)
            let block = box(padding: 0)
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(NSColor.separatorColor, for: .maxY)
            layout.edit(range) { _, style in style.textBlocks.append(block) }
        }
    }

    /// The colours `CodeBlockView` gives the same tokens.
    private static func color(for kind: CodeToken.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemOrange
        case .plain: .labelColor
        }
    }

    private static func quoteBlock() -> NSTextBlock {
        let block = box(padding: 2)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(NSColor.controlAccentColor.withAlphaComponent(0.4), for: .minX)
        return block
    }

    /// Wrapped lines hang under the item's text, not under its marker.
    private static func applyListItem(
        _ run: DocumentStyleRun,
        marker: Int,
        to out: NSMutableAttributedString,
        layout: inout ParagraphLayout,
        typography type: DocumentTypography
    ) {
        let prefix = (out.string as NSString).substring(with: NSRange(location: run.location, length: min(marker, run.length)))
        let indent = ceil((prefix as NSString).size(withAttributes: [.font: type.bodyFont]).width)
        layout.edit(NSRange(location: run.location, length: run.length)) { paragraph, style in
            style.headIndent = indent
            style.firstLineHeadIndent = paragraph.location == run.location ? 0 : indent
        }
    }

    private static func applyTableCell(
        _ cell: DocumentTableCell,
        range: NSRange,
        to out: NSMutableAttributedString,
        layout: inout ParagraphLayout,
        typography type: DocumentTypography
    ) {
        if cell.header { convertFonts(in: out, range: range, trait: .boldFontMask, typography: type) }
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
    }

    /// Adds `trait` to every font already in `range` (bold code stays
    /// monospaced, a bold word in a heading keeps the heading size).
    private static func convertFonts(
        in out: NSMutableAttributedString,
        range: NSRange,
        trait: NSFontTraitMask,
        typography type: DocumentTypography
    ) {
        out.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? type.bodyFont
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
        /// What each paragraph is, for a typography with a rhythm; the
        /// innermost run wins (a code block in a list item is code).
        private var roles: [Int: DocumentTypography.Role] = [:]

        init(string: NSString) {
            self.string = string
        }

        /// Calls `body` with each paragraph `range` touches and its style.
        mutating func edit(_ range: NSRange, _ body: (NSRange, NSMutableParagraphStyle) -> Void) {
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let style = styles[paragraph.location] ?? NSMutableParagraphStyle()
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

        mutating func mark(_ range: NSRange, _ role: DocumentTypography.Role) {
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                roles[paragraph.location] = role
                location = NSMaxRange(paragraph)
            }
        }

        func commit(to out: NSMutableAttributedString, typography type: DocumentTypography) {
            guard let rhythm = type.rhythm else {
                for (location, style) in styles {
                    let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                    out.addAttribute(.paragraphStyle, value: style, range: paragraph)
                }
                return
            }
            // Every paragraph gets its line height and spacing.
            let styler = DocumentTypography.Styler(type, rhythm: rhythm)
            var location = 0
            while location < string.length {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                let style = styles[paragraph.location] ?? NSMutableParagraphStyle()
                let role = roles[paragraph.location] ?? .body
                if role == .body, paragraph.length == 1, string.character(at: paragraph.location) == 0x0A {
                    // The blank line every block ends with: the spacing
                    // sets the rhythm, so it is kept small.
                    out.addAttribute(.font, value: NSFont.systemFont(ofSize: rhythm.blankLineSize), range: paragraph)
                } else {
                    styler.apply(role, to: style)
                }
                out.addAttribute(.paragraphStyle, value: style, range: paragraph)
                location = NSMaxRange(paragraph)
            }
        }
    }
}
