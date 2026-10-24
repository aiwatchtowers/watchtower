import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore

/// A finished answer's table (spec 2026-10-24 §5c, ask #541): one
/// read-only, selectable native text view instead of a selectable SwiftUI
/// `Text` per cell. Same look as `MarkdownTableView` — semibold header, a
/// divider under it, the grid's column and row spacing, column alignment,
/// the padded tinted background — and a horizontal scroll view only when
/// the table is wider than the column. A streaming answer keeps
/// `MarkdownTableView`.
struct NativeMarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.markdownCodeLinks) private var codeLinks
    @Environment(\.markdownNavScreens) private var navScreens

    var body: some View {
        let text = MarkdownTableText.attributed(table, links: InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens))
        ViewThatFits(in: .horizontal) {
            grid(text).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { grid(text) }
        }
        .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.control))
    }

    private func grid(_ text: NSAttributedString) -> some View {
        MarkdownTableRun(text: text, codeLinks: codeLinks, navScreens: navScreens).padding(Spacing.regular)
    }
}

/// A `MarkdownTable` → the text of its native view. Each row is one
/// paragraph whose cells are separated by tabs, so a selection reads (and
/// ⌘C copies) as tab-separated cells, one line per row. Every cell sits at
/// its column's tab stop, offset inside the column by the column's
/// alignment; the first cell by the row's first-line indent. Cells never
/// wrap, as the grid's: the view lays the text out unbounded. A line
/// break or a tab inside a cell reads as a space.
enum MarkdownTableText {
    /// `MarkdownTableView`'s grid spacing.
    static let columnSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 6
    /// The divider under the header row (a SwiftUI `Divider`).
    static let dividerThickness: CGFloat = 1

    private struct Key: Hashable {
        let table: MarkdownTable
        let links: InlineLinkContext
    }

    /// Cost = characters, as the run memo.
    private static let memo = MarkdownMemo<Key, NSAttributedString>(totalCostLimit: 2 << 20)

    static func attributed(_ table: MarkdownTable, links: InlineLinkContext) -> NSAttributedString {
        memo.value(for: Key(table: table, links: links), cost: { $0.length }, build: { build(table, links: links) })
    }

    private static func build(_ table: MarkdownTable, links: InlineLinkContext) -> NSAttributedString {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        func cells(_ row: [[MarkdownInline]], weight: NSFont.Weight) -> [NSAttributedString] {
            (0..<columns).map { column in
                let out = NSMutableAttributedString()
                if column < row.count {
                    MarkdownRunText.appendInlines(row[column], links: links, size: MarkdownRunText.bodyFont.pointSize,
                                                  weight: weight, color: .labelColor, lineBreak: " ", to: out)
                    // A tab the cell's text keeps would move the rest of the
                    // row to the next stop and split the cell in a copy.
                    out.mutableString.replaceOccurrences(of: "\t", with: " ", options: [],
                                                         range: NSRange(location: 0, length: out.length))
                }
                return out
            }
        }
        let rows = [cells(table.header, weight: .semibold)] + table.rows.map { cells($0, weight: .regular) }
        let widths = rows.map { $0.map { ceil($0.size().width) } }
        let columnWidths = (0..<columns).map { column in widths.map { $0[column] }.max() ?? 0 }
        var columnStarts: [CGFloat] = [0]
        for width in columnWidths.dropLast() {
            columnStarts.append((columnStarts.last ?? 0) + width + columnSpacing)
        }

        let out = NSMutableAttributedString()
        let tab = NSAttributedString(string: "\t", attributes: [.font: MarkdownRunText.bodyFont])
        for (index, row) in rows.enumerated() {
            let start = out.length
            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: MarkdownRunText.bodyFont])) }
            let stops = (0..<columns).map { column in
                columnStarts[column] + offset(alignment(of: column, in: table), cell: widths[index][column],
                                              column: columnWidths[column])
            }
            for (column, cell) in row.enumerated() {
                if column > 0 { out.append(tab) }
                out.append(cell)
            }
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = stops.first ?? 0
            style.tabStops = stops.dropFirst().map { NSTextTab(textAlignment: .left, location: $0) }
            style.lineBreakMode = .byClipping
            style.paragraphSpacingBefore = switch index {
            case 0: 0
            case 1: rowSpacing + dividerThickness + rowSpacing
            default: rowSpacing
            }
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    private static func alignment(of column: Int, in table: MarkdownTable) -> MarkdownAlignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    /// Where a cell `cell` wide starts inside its `column`-wide column.
    private static func offset(_ alignment: MarkdownAlignment, cell: CGFloat, column: CGFloat) -> CGFloat {
        switch alignment {
        case .leading: 0
        case .center: ((column - cell) / 2).rounded()
        case .trailing: column - cell
        }
    }
}

/// A table's read-only text view: the run view (selection, plain-text
/// copy, the gated menu, leaving drops the selection) with the table's own
/// width rule — the text is laid out unbounded, so no frame or size probe
/// ever wraps a row, and the size is the table's own whatever is proposed —
/// and the divider under the header row.
final class MarkdownTableTextView: MarkdownRunTextView {
    /// Wide enough for any table; rows never wrap.
    private static let unbounded: CGFloat = 100_000

    static func makeTable() -> MarkdownTableTextView {
        let view = MarkdownTableTextView(usingTextLayoutManager: true)
        view.configureForReading()
        view.textContainer?.size = CGSize(width: unbounded, height: .greatestFiniteMagnitude)
        view.setAccessibilityRoleDescription("table")
        return view
    }

    override func containerWidth(forViewWidth width: CGFloat) -> CGFloat { Self.unbounded }

    /// The table's size: its widest row and its rows' height.
    override func fittingSize(width: CGFloat) -> CGSize {
        super.fittingSize(width: Self.unbounded)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawDivider(in: dirtyRect)
    }

    /// The header row's divider, the table's width, a row spacing below
    /// the header's line.
    private func drawDivider(in dirtyRect: NSRect) {
        guard let layout = textLayoutManager,
              let header = layout.textLayoutFragment(for: layout.documentRange.location),
              let line = header.textLineFragments.last else { return }
        let rect = CGRect(x: 0, y: textContainerOrigin.y + header.layoutFragmentFrame.minY + line.typographicBounds.maxY
                              + MarkdownTableText.rowSpacing,
                          width: bounds.width, height: MarkdownTableText.dividerThickness)
        guard rect.intersects(dirtyRect) else { return }
        NSColor.separatorColor.setFill()
        rect.fill()
    }
}

/// A table's native text view in SwiftUI. Links take the run's gate
/// (`MarkdownTextRun.Coordinator`); the size is the table's own.
struct MarkdownTableRun: NSViewRepresentable {
    let text: NSAttributedString
    let codeLinks: Bool
    let navScreens: Set<String>

    func makeCoordinator() -> MarkdownTextRun.Coordinator { MarkdownTextRun.Coordinator() }

    func makeNSView(context: Context) -> MarkdownTableTextView {
        let view = MarkdownTableTextView.makeTable()
        view.delegate = context.coordinator
        view.show(text)
        return view
    }

    func updateNSView(_ view: MarkdownTableTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.links = InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens)
        view.show(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTableTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width ?? 0)
    }
}
