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
    /// `AllowedURLSchemes.permits` never allows them).
    static func inlineText(_ inlines: [MarkdownInline], codeLinks: Bool = false) -> AttributedString {
        AllowedURLSchemes.strippingDisallowedLinks(MarkdownInlineRenderer.attributed(inlines),
                                                   renderOnly: codeLinks ? [CodeLineLinks.scheme] : [])
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
    @Environment(\.markdownCodeLinks) private var codeLinks

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
        Text(MarkdownView.inlineText(inlines, codeLinks: codeLinks)).fixedSize(horizontal: false, vertical: true)
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
    @Environment(\.markdownCodeLinks) private var codeLinks

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(MarkdownView.inlineText(table.header[column], codeLinks: codeLinks))
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            Text(MarkdownView.inlineText(table.rows[row][column], codeLinks: codeLinks))
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

private struct MarkdownCodeLinksKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether `MarkdownView` links `path:line` citations (code answers).
    var markdownCodeLinks: Bool {
        get { self[MarkdownCodeLinksKey.self] }
        set { self[MarkdownCodeLinksKey.self] = newValue }
    }
}
