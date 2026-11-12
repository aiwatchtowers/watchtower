import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore

/// A finished answer's table (spec 2026-10-24 §5c, ask #541): one
/// read-only, selectable native text view instead of a selectable SwiftUI
/// `Text` per cell. Same look as `MarkdownTableView` — semibold header, a
/// divider under it, the grid's column and row spacing, column alignment,
/// the padded tinted background. No scroll view: a table wider than the
/// column fills it and its wide columns wrap (`MarkdownTableColumns`, ask
/// #1197). A streaming answer keeps `MarkdownTableView`.
struct NativeMarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.markdownCodeLinks) private var codeLinks
    @Environment(\.markdownNavScreens) private var navScreens

    var body: some View {
        MarkdownTableRun(table: table, links: InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens))
            .padding(Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// A `MarkdownTable` → the text of its native view: an `NSTextTable` with
/// one paragraph per cell, each cell block as wide as its column at the
/// width the table has (`MarkdownTableColumns`), so a wide column wraps at
/// word boundaries and a row is as tall as its tallest cell. The end of a
/// cell reads as a tab and the end of a row as a newline
/// (`.markdownPlainText`), so a selection reads (and ⌘C copies) as
/// tab-separated cells, one line per row. A line break or a tab inside a
/// cell reads as a space.
enum MarkdownTableText {
    /// `MarkdownTableView`'s grid spacing.
    static let columnSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 6
    /// The divider under the header row (a SwiftUI `Divider`).
    static let dividerThickness: CGFloat = 1
    /// A column that has to wrap keeps at least its longest word, up to
    /// this, so a short header does not break mid-word.
    static let maxMinimumWidth: CGFloat = 120

    /// A table's cells and the widths its columns want.
    struct Metrics {
        /// Rows (the header first) of `columns` cells each.
        let cells: [[NSAttributedString]]
        let natural: [CGFloat]
        let minimum: [CGFloat]
        var columns: Int { natural.count }

        /// The columns' widths for a table `width` wide (gaps included);
        /// nil, zero or not finite: the natural widths.
        func columnWidths(for width: CGFloat?) -> [CGFloat] {
            let gaps = columnSpacing * CGFloat(max(0, columns - 1))
            let available = width.map { $0 - gaps } ?? .infinity
            return MarkdownTableColumns.widths(natural: natural, minimum: minimum,
                                               available: (width ?? 0) > 0 ? max(available, 1) : .infinity)
        }

        /// The table's width for a `width`-wide column: its natural width
        /// when it fits, else exactly `width` — never the sum of the
        /// rounded columns, so the frame SwiftUI gives it back lays out
        /// the same columns as the probe that measured it.
        func tableWidth(for width: CGFloat?) -> CGFloat {
            let natural = natural.reduce(0, +) + columnSpacing * CGFloat(max(0, columns - 1))
            guard let width, width.isFinite, width > 0, natural > width else { return natural }
            return width
        }
    }

    private struct Key: Hashable {
        let table: MarkdownTable
        let links: InlineLinkContext
    }

    private struct TextKey: Hashable {
        let table: MarkdownTable
        let links: InlineLinkContext
        let widths: [CGFloat]
    }

    private static let metricsMemo = MarkdownMemo<Key, Metrics>(totalCostLimit: 1 << 20)
    /// Cost = characters, as the run memo.
    private static let memo = MarkdownMemo<TextKey, NSAttributedString>(totalCostLimit: 2 << 20)

    static func metrics(_ table: MarkdownTable, links: InlineLinkContext) -> Metrics {
        metricsMemo.value(for: Key(table: table, links: links),
                          cost: { $0.cells.reduce(0) { $0 + $1.reduce(0) { $0 + $1.length } } },
                          build: { buildMetrics(table, links: links) })
    }

    /// The table's text laid out for a table `width` wide (nil: natural).
    static func attributed(_ table: MarkdownTable, links: InlineLinkContext, width: CGFloat? = nil) -> NSAttributedString {
        let metrics = metrics(table, links: links)
        let widths = metrics.columnWidths(for: width)
        return memo.value(for: TextKey(table: table, links: links, widths: widths), cost: { $0.length },
                          build: { build(table, metrics: metrics, widths: widths) })
    }

    private static func buildMetrics(_ table: MarkdownTable, links: InlineLinkContext) -> Metrics {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        func cells(_ row: [[MarkdownInline]], weight: NSFont.Weight) -> [NSAttributedString] {
            (0..<columns).map { column in
                let out = NSMutableAttributedString()
                if column < row.count {
                    MarkdownRunText.appendInlines(row[column], links: links, size: MarkdownRunText.bodyFont.pointSize,
                                                  weight: weight, color: .labelColor, lineBreak: " ", to: out)
                    // A tab the cell's text keeps would read as a cell end
                    // in a copy.
                    out.mutableString.replaceOccurrences(of: "\t", with: " ", options: [],
                                                         range: NSRange(location: 0, length: out.length))
                }
                return out
            }
        }
        let rows = [cells(table.header, weight: .semibold)] + table.rows.map { cells($0, weight: .regular) }
        let natural = (0..<columns).map { column in rows.map { ceil($0[column].size().width) }.max() ?? 0 }
        let minimum = (0..<columns).map { column in
            min(maxMinimumWidth, rows.map { longestWord($0[column]) }.max() ?? 0)
        }
        return Metrics(cells: rows, natural: natural, minimum: minimum)
    }

    /// The widest run of non-space characters in `cell`.
    private static func longestWord(_ cell: NSAttributedString) -> CGFloat {
        let string = cell.string as NSString
        var widest: CGFloat = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { _, range, _, _ in
            widest = max(widest, ceil(cell.attributedSubstring(from: range).size().width))
        }
        return widest
    }

    private static func build(_ table: MarkdownTable, metrics: Metrics, widths: [CGFloat]) -> NSAttributedString {
        let textTable = NSTextTable()
        textTable.numberOfColumns = metrics.columns
        textTable.collapsesBorders = false
        textTable.hidesEmptyCells = false
        let out = NSMutableAttributedString()
        let font = MarkdownRunText.bodyFont
        let lastRow = metrics.cells.count - 1
        for (row, cells) in metrics.cells.enumerated() {
            for (column, cell) in cells.enumerated() {
                let start = out.length
                out.append(cell)
                let lastCell = row == lastRow && column == metrics.columns - 1
                if !lastCell {
                    let end = column == metrics.columns - 1 ? "\n" : "\t"
                    out.append(NSAttributedString(string: "\n", attributes: [.font: font, .markdownPlainText: end]))
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block(textTable, row: row, column: column, width: widths[column], last: column == widths.count - 1)]
                style.alignment = alignment(of: column, in: table)
                style.lineBreakMode = .byWordWrapping
                out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
            }
        }
        return out
    }

    /// A cell `width` wide; the column gap is its trailing padding, the
    /// row gap its top padding; the header's cells draw the divider as
    /// their bottom border, a row gap below the header's text.
    private static func block(_ table: NSTextTable, row: Int, column: Int, width: CGFloat, last: Bool) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setValue(width, type: .absoluteValueType, for: .width)
        block.setWidth(last ? 0 : columnSpacing, type: .absoluteValueType, for: .padding, edge: .maxX)
        if row == 0 {
            block.setWidth(rowSpacing, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(dividerThickness, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(.separatorColor, for: .maxY)
        } else {
            block.setWidth(rowSpacing, type: .absoluteValueType, for: .padding, edge: .minY)
        }
        return block
    }

    private static func alignment(of column: Int, in table: MarkdownTable) -> NSTextAlignment {
        switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}

/// A table's read-only text view: the run view (selection, plain-text
/// copy, the gated menu, leaving drops the selection) on TextKit 1, which
/// lays out an `NSTextTable` (TextKit 2 does not). Its text depends on its
/// width: a size probe lays the table out at the probe's width and puts
/// the frame's text back, so the shown table never keeps a probe's columns.
final class MarkdownTableTextView: MarkdownRunTextView {
    /// The table's own blocks set its width; the container never wraps it.
    private static let unbounded: CGFloat = 100_000

    private var source: (table: MarkdownTable, links: InlineLinkContext)?
    private var sizes: [(width: CGFloat, size: CGSize)] = []
    private var measuring = false

    static func makeTable() -> MarkdownTableTextView {
        let view = MarkdownTableTextView(usingTextLayoutManager: false)
        view.configureForReading()
        view.textContainer?.size = CGSize(width: unbounded, height: .greatestFiniteMagnitude)
        view.setAccessibilityRoleDescription("table")
        return view
    }

    /// Shows `table`, laid out at the view's width (natural until it has one).
    func show(_ table: MarkdownTable, links: InlineLinkContext) {
        if let source, source.table == table, source.links == links { return }
        source = (table, links)
        sizes = []
        layOut(frame.width)
    }

    override func containerWidth(forViewWidth width: CGFloat) -> CGFloat { Self.unbounded }

    /// The table's size at `width`: its columns' widths and its rows'
    /// height. Zero, not finite or past the table's natural width: the
    /// natural table.
    override func fittingSize(width: CGFloat) -> CGSize {
        let width = width.isFinite && width > 0 ? width : 0
        if let hit = sizes.first(where: { $0.width == width }) { return hit.size }
        guard let source, let layout = layoutManager, let container = textContainer else { return .zero }
        let metrics = MarkdownTableText.metrics(source.table, links: source.links)
        measuring = true
        layOut(width)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height
        measuring = false
        let size = CGSize(width: metrics.tableWidth(for: width > 0 ? width : nil), height: ceil(height))
        if frame.width > 0 { layOut(frame.width) }
        sizes = [(width, size)] + sizes.prefix(1)
        return size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !measuring, newSize.width > 0 { layOut(newSize.width) }
    }

    /// Shows the table's text for `width` (0: natural); the text is the
    /// same at every width, so a selection stays where it was.
    private func layOut(_ width: CGFloat) {
        guard let source else { return }
        let selection = selectedRanges
        show(MarkdownTableText.attributed(source.table, links: source.links, width: width > 0 ? width : nil))
        let length = (string as NSString).length
        if selectedRanges != selection, selection.allSatisfy({ NSMaxRange($0.rangeValue) <= length }) {
            selectedRanges = selection
        }
    }

    /// VoiceOver reads the table row by row, its cells in order.
    override func accessibilityValue() -> String? { plainText }
}

/// A table's native text view in SwiftUI. Links take the run's gate
/// (`MarkdownTextRun.Coordinator`); the size is the table's at the
/// proposed width.
struct MarkdownTableRun: NSViewRepresentable {
    let table: MarkdownTable
    let links: InlineLinkContext

    func makeCoordinator() -> MarkdownTextRun.Coordinator { MarkdownTextRun.Coordinator() }

    func makeNSView(context: Context) -> MarkdownTableTextView {
        let view = MarkdownTableTextView.makeTable()
        view.delegate = context.coordinator
        view.show(table, links: links)
        return view
    }

    func updateNSView(_ view: MarkdownTableTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.links = links
        view.show(table, links: links)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTableTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width ?? 0)
    }
}
