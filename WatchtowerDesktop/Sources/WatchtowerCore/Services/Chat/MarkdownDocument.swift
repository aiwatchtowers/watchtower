import Foundation
import Markdown

package enum MarkdownTaskState: Equatable, Sendable { case none, checked, unchecked }

package enum MarkdownAlignment: Equatable, Sendable { case leading, center, trailing }

package struct MarkdownListItem: Equatable, Sendable {
    package let task: MarkdownTaskState
    package let blocks: [MarkdownBlock]

    package init(task: MarkdownTaskState, blocks: [MarkdownBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

package struct MarkdownList: Equatable, Sendable {
    package let ordered: Bool
    package let start: Int
    package let items: [MarkdownListItem]

    package init(ordered: Bool, start: Int, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

package struct MarkdownTable: Equatable, Sendable {
    package let header: [[MarkdownInline]]
    package let rows: [[[MarkdownInline]]]
    package let alignments: [MarkdownAlignment]

    package init(header: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [MarkdownAlignment]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }
}

package indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph([MarkdownInline])
    case code(language: String?, code: String)
    case list(MarkdownList)
    case quote([Self])
    case table(MarkdownTable)
    case rule
}

package indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([Self])
    case strong([Self])
    case strikethrough([Self])
    case code(String)
    case link(destination: String, children: [Self])
    case lineBreak
    case softBreak
}

/// swift-markdown (cmark-gfm) → our render model. Pure and memoized: chat
/// transcripts rebuild rows while scrolling, and the streaming row re-parses
/// at ≤30 fps — only that row, since finished rows hit the cache.
package enum MarkdownDocument {
    private final class Box {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    package static func parse(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = Document(parsing: text).children.compactMap(block)
        cache.setObject(Box(blocks), forKey: key, cost: text.utf16.count)
        return blocks
    }

    private static func block(_ node: Markup) -> MarkdownBlock? {
        switch node {
        case let heading as Heading: .heading(level: heading.level, inlines: inlines(heading))
        case let paragraph as Paragraph: .paragraph(inlines(paragraph))
        case let code as CodeBlock: .code(language: nonEmpty(code.language), code: trimTrailingNewline(code.code))
        case let list as UnorderedList: .list(MarkdownList(ordered: false, start: 1, items: list.listItems.map(item)))
        case let list as OrderedList: .list(MarkdownList(ordered: true, start: Int(list.startIndex), items: list.listItems.map(item)))
        case let quote as BlockQuote: .quote(quote.children.compactMap(block))
        case let table as Markdown.Table: .table(self.table(table))
        case is ThematicBreak: .rule
        case let html as HTMLBlock: .paragraph([.text(html.rawHTML)])
        default: nil
        }
    }

    private static func item(_ item: ListItem) -> MarkdownListItem {
        let task: MarkdownTaskState = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case .none: .none
        }
        return MarkdownListItem(task: task, blocks: item.children.compactMap(block))
    }

    private static func table(_ table: Markdown.Table) -> MarkdownTable {
        let header = table.head.cells.map { inlines($0) }
        let rows = table.body.rows.map { row in Array(row.cells.map { inlines($0) }) }
        let alignments: [MarkdownAlignment] = table.columnAlignments.map { alignment in
            switch alignment {
            case .center: .center
            case .right: .trailing
            case .left, .none: .leading
            }
        }
        return MarkdownTable(header: Array(header), rows: Array(rows), alignments: alignments)
    }

    private static func inlines(_ node: Markup) -> [MarkdownInline] {
        node.children.compactMap(inline)
    }

    private static func inline(_ node: Markup) -> MarkdownInline? {
        switch node {
        case let text as Markdown.Text: .text(text.string)
        case let emphasis as Emphasis: .emphasis(inlines(emphasis))
        case let strong as Strong: .strong(inlines(strong))
        case let strike as Strikethrough: .strikethrough(inlines(strike))
        case let code as InlineCode: .code(code.code)
        case let link as Markdown.Link: .link(destination: link.destination ?? "", children: inlines(link))
        case let image as Markdown.Image: .link(destination: image.source ?? "", children: inlines(image))
        case is LineBreak: .lineBreak
        case is SoftBreak: .softBreak
        case let html as InlineHTML: .text(html.rawHTML)
        default: nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func trimTrailingNewline(_ code: String) -> String {
        code.hasSuffix("\n") ? String(code.dropLast()) : code
    }
}

/// Inline model → AttributedString with Foundation presentation intents
/// (SwiftUI `Text` renders them). Link sanitizing is the app's job
/// (`AllowedURLSchemes`), applied by `MarkdownView.inlineText`.
package enum MarkdownInlineRenderer {
    package static func attributed(_ inlines: [MarkdownInline]) -> AttributedString {
        inlines.reduce(into: AttributedString()) { $0 += render($1, intent: [], link: nil) }
    }

    private static func render(_ inline: MarkdownInline, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        switch inline {
        case let .text(value): styled(value, intent, link)
        case let .code(value): styled(value, intent.union(.code), link)
        case let .emphasis(children): group(children, intent.union(.emphasized), link)
        case let .strong(children): group(children, intent.union(.stronglyEmphasized), link)
        case let .strikethrough(children): group(children, intent.union(.strikethrough), link)
        case let .link(destination, children): group(children, intent, URL(string: destination))
        case .lineBreak: styled("\n", intent, link)
        case .softBreak: styled(" ", intent, link)
        }
    }

    private static func group(_ children: [MarkdownInline], _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        children.reduce(into: AttributedString()) { $0 += render($1, intent: intent, link: link) }
    }

    private static func styled(_ value: String, _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        var out = AttributedString(value)
        if !intent.isEmpty { out.inlinePresentationIntent = intent }
        out.link = link
        return out
    }
}
