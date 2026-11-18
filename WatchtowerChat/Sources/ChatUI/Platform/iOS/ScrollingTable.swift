#if os(iOS)
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// A Markdown table that scrolls sideways (the phone only; the Mac lays its tables out to the column width).
struct ScrollingTable: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.compact) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownRuns.inline(cell)).font(.callout.weight(.semibold))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownRuns.inline(cell)).font(.callout)
                        }
                    }
                }
            }
            .padding(Spacing.regular)
        }
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}
#endif
