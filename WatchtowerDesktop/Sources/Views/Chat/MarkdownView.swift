import DesignKit
import SwiftUI
import WatchtowerCore

/// The one markdown renderer for every chat surface (spec §3.3) — main chat,
/// Discuss chats, setup assistants, recording notes, memory pages.
///
/// No `.environment(\.openURL, …)` here: an `OpenURLAction` cannot be
/// compared, so re-applying it on every body pass (each streamed delta)
/// invalidates every `Text` below and re-lays the whole message out — ~5×
/// the cost of a delta without it (`TextRenderingBenchmarkTests`). Links stay
/// gated: `inlineText` strips every disallowed-scheme link before it renders,
/// and the main, Settings, Progress and Logs window roots also install the
/// app-wide gate. A surface's own handler (MemoryView's wiki links) is no
/// longer shadowed.
struct MarkdownView: View {
    let text: String
    /// Text the owner wrote: one newline is a new line
    /// (`MarkdownDocument.withLineBreaks`); the agent's text keeps markdown's
    /// soft breaks.
    var lineBreaks = false
    /// A code answer's `path:line` citations as links (`CodeLineLinks`);
    /// set by the code question popover, whose own `openURL` opens them.
    @Environment(\.markdownCodeLinks) private var codeLinks

    var body: some View {
        let blocks = MarkdownDocument.parse(codeLinks ? CodeLineLinks.linkified(text) : text)
        MarkdownBlocksView(blocks: lineBreaks ? MarkdownDocument.withLineBreaks(blocks) : blocks)
            .textSelection(.enabled)
    }

    /// Inline render with disallowed-scheme links stripped (the gate every
    /// markdown link passes). `codeLinks` also keeps `watchtower-code`
    /// links, which only the code question popover opens (render-only:
    /// `AllowedURLSchemes.permits` never allows them); `navScreens` keeps
    /// the screen links (`watchtower-nav`) to those screens only.
    /// Memoised per inline run and link context (`MarkdownInlineRenderer
    /// .memoized`): the stripped text is what the memo holds, so a hit is
    /// as gated as a fresh build.
    static func inlineText(
        _ inlines: [MarkdownInline], codeLinks: Bool = false, navScreens: Set<String> = []
    ) -> AttributedString {
        inlineText(inlines, links: InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens))
    }

    static func inlineText(_ inlines: [MarkdownInline], links: InlineLinkContext) -> AttributedString {
        MarkdownInlineRenderer.memoized(inlines, context: links) {
            AllowedURLSchemes.strippingDisallowedLinks(MarkdownInlineRenderer.attributed($0),
                                                       renderOnly: links.renderOnly, navScreens: links.navScreens)
        }
    }

    /// One line of markdown as a label (a button's, an ask's focus place):
    /// its inline styling without links — the label's own action is the
    /// click. Text that is not a single paragraph shows as written.
    static func inlineLabel(_ text: String) -> AttributedString {
        let blocks = MarkdownDocument.parse(text)
        guard blocks.count == 1, case let .paragraph(inlines) = blocks[0] else { return AttributedString(text) }
        var result = MarkdownInlineRenderer.attributed(inlines)
        let links = result.runs.compactMap { $0.link == nil ? nil : $0.range }
        for range in links {
            result[range].link = nil
        }
        return result
    }
}

/// Everything besides the inlines that rendered markdown text depends on:
/// the surface's link rules (`MarkdownView.inlineText`, `MarkdownRunText`).
struct InlineLinkContext: Hashable, Sendable {
    let codeLinks: Bool
    let navScreens: Set<String>

    /// Schemes the surface opens itself (`AllowedURLSchemes.keepsLink`).
    var renderOnly: Set<String> { codeLinks ? [CodeLineLinks.scheme] : [] }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownRunBuilder.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.markdownCodeLinks) private var codeLinks
    @Environment(\.markdownNavScreens) private var navScreens

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            inline(inlines).font(Self.headingFont(level)).fontWeight(.bold)
        case let .paragraph(inlines):
            inline(inlines)
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .list(list):
            MarkdownListView(list: list)
        case let .quote(children):
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(width: 3)
                MarkdownBlocksView(blocks: children).foregroundStyle(.secondary).padding(.leading, 8)
            }
        case let .table(table):
            MarkdownTableView(table: table)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    // fixedSize keeps long lines wrapping inside HStack rows (AppKit-backed
    // Text otherwise truncates to one line).
    private func inline(_ inlines: [MarkdownInline]) -> some View {
        Text(MarkdownView.inlineText(inlines, codeLinks: codeLinks, navScreens: navScreens)).fixedSize(horizontal: false, vertical: true)
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownRunBuilder.itemSpacing) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: MarkdownRunText.markerGap) {
                    marker(for: list.items[index], index: index)
                    MarkdownBlocksView(blocks: list.items[index].blocks)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, index: Int) -> some View {
        switch item.task {
        case .checked: Image(systemName: "checkmark.square").foregroundStyle(.secondary)
        case .unchecked: Image(systemName: "square").foregroundStyle(.secondary)
        case .none:
            Text(list.ordered ? "\(list.start + index)." : "\u{2022}")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.markdownCodeLinks) private var codeLinks
    @Environment(\.markdownNavScreens) private var navScreens

    /// No scroll view (spec 2026-10-24 §5b: each one is a cost while the
    /// chat scrolls): a table wider than the column fills it and its wide
    /// columns wrap (`MarkdownTableColumns`, ask #1197), as the finished
    /// answer's `NativeMarkdownTableView`.
    var body: some View {
        let links = InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens)
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        MarkdownTableGrid(metrics: MarkdownTableText.metrics(table, links: links), alignments: table.alignments) {
            row(table.header, columns: columns, weight: .semibold)
            Rectangle().fill(Color(nsColor: .separatorColor))
            ForEach(table.rows.indices, id: \.self) { index in
                row(table.rows[index], columns: columns, weight: .regular)
            }
        }
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// `columns` cells; a short row's missing ones are empty. A wrapped
    /// cell's lines take the column's alignment, as the native table's.
    private func row(_ cells: [[MarkdownInline]], columns: Int, weight: Font.Weight) -> some View {
        ForEach(0..<columns, id: \.self) { column in
            Text(column < cells.count ? MarkdownView.inlineText(cells[column], codeLinks: codeLinks, navScreens: navScreens)
                                      : AttributedString())
                .fontWeight(weight)
                .multilineTextAlignment(textAlignment(column))
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// The streaming table's layout: the header's cells, a divider, then each
/// row's cells, every row `metrics.columns` cells. Columns are as wide as
/// `MarkdownTableColumns` gives them at the proposed width — natural widths
/// from the cells themselves (whatever font the surface sets), minimums
/// from `metrics` —, a cell wraps inside its column and a row is as tall as
/// its tallest cell, with the grid's column and row spacing.
struct MarkdownTableGrid: Layout {
    let metrics: MarkdownTableText.Metrics
    let alignments: [MarkdownAlignment]

    private var columns: Int { max(metrics.columns, 1) }

    /// The cells' own natural widths per column, the divider skipped.
    func makeCache(subviews: Subviews) -> MarkdownTableText.Metrics {
        var natural = [CGFloat](repeating: 0, count: columns)
        for (index, cell) in subviews.enumerated() where index != columns {
            let column = (index > columns ? index - 1 : index) % columns
            natural[column] = max(natural[column], ceil(cell.sizeThatFits(.unspecified).width))
        }
        let minimum = natural.indices.map { min(natural[$0], $0 < metrics.minimum.count ? metrics.minimum[$0] : 0) }
        return MarkdownTableText.Metrics(cells: [], natural: natural, minimum: minimum)
    }

    func updateCache(_ cache: inout MarkdownTableText.Metrics, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private static func width(_ proposal: ProposedViewSize) -> CGFloat? {
        proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Each row's height (the divider is its own row of one).
    private func rowHeights(_ subviews: Subviews, widths: [CGFloat]) -> [CGFloat] {
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            if heights.count == 1 {
                heights.append(MarkdownTableText.dividerThickness)
                index += 1
                continue
            }
            let cells = subviews[index..<min(index + columns, subviews.count)]
            let cellHeights = cells.enumerated().map { column, cell in
                ceil(cell.sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height)
            }
            heights.append(cellHeights.max() ?? 0)
            index += columns
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout MarkdownTableText.Metrics) -> CGSize {
        let width = Self.width(proposal)
        let heights = rowHeights(subviews, widths: cache.columnWidths(for: width))
        return CGSize(width: cache.tableWidth(for: width),
                      height: heights.reduce(0, +) + MarkdownTableText.rowSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout MarkdownTableText.Metrics
    ) {
        let widths = cache.columnWidths(for: Self.width(proposal))
        let heights = rowHeights(subviews, widths: widths)
        var y = bounds.minY
        var index = 0
        for (row, height) in heights.enumerated() {
            if row == 1 {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: bounds.width, height: height))
                index += 1
            } else {
                var x = bounds.minX
                for column in 0..<columns where index < subviews.count {
                    let width = widths[column]
                    let (point, anchor): (CGPoint, UnitPoint) = switch column < alignments.count ? alignments[column] : .leading {
                    case .leading: (CGPoint(x: x, y: y), .topLeading)
                    case .center: (CGPoint(x: x + width / 2, y: y), .top)
                    case .trailing: (CGPoint(x: x + width, y: y), .topTrailing)
                    }
                    subviews[index].place(at: point, anchor: anchor, proposal: ProposedViewSize(width: width, height: nil))
                    x += width + MarkdownTableText.columnSpacing
                    index += 1
                }
            }
            y += height + MarkdownTableText.rowSpacing
        }
    }
}

private struct MarkdownCodeLinksKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MarkdownNavScreensKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    /// Whether `MarkdownView` links `path:line` citations (code answers).
    var markdownCodeLinks: Bool {
        get { self[MarkdownCodeLinksKey.self] }
        set { self[MarkdownCodeLinksKey.self] = newValue }
    }

    /// The screens a `watchtower-nav://` link may open (the main window's
    /// visible sidebar screens); every other screen link renders as text.
    var markdownNavScreens: Set<String> {
        get { self[MarkdownNavScreensKey.self] }
        set { self[MarkdownNavScreensKey.self] = newValue }
    }
}
