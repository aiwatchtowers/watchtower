import SwiftUI
import WatchtowerCore

/// The one markdown renderer for every chat surface (spec §3.3) — main chat,
/// Discuss chats, setup assistants, recording notes, memory pages.
struct MarkdownView: View {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownDocument.parse(text))
            .textSelection(.enabled)
            .environment(\.openURL, AllowedURLSchemes.openURLAction)
    }

    /// Inline render with disallowed-scheme links stripped (defence in depth
    /// on top of the app-wide `openURL` gate).
    static func inlineText(_ inlines: [MarkdownInline]) -> AttributedString {
        AllowedURLSchemes.strippingDisallowedLinks(MarkdownInlineRenderer.attributed(inlines))
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

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
        Text(MarkdownView.inlineText(inlines)).fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(MarkdownView.inlineText(table.header[column]))
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            Text(MarkdownView.inlineText(table.rows[row][column]))
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
