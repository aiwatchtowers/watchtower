import SwiftUI
import WatchtowerChatText

/// An answer's Markdown (iPhone chat spec §6.2): the shared parse and run builder (`MarkdownDocument`,
/// `MarkdownRunBuilder`, the Mac's), drawn in SwiftUI — headings, lists, quotes and inline styles as text runs;
/// code blocks, tables and rules as their own views. Code and tables scroll sideways on the phone.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        let segments = MarkdownRunBuilder.segments(MarkdownDocument.parse(text))
        VStack(alignment: .leading, spacing: MarkdownRunBuilder.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .textRun(run): ChatMarkdownRun(run: run)
                case let .block(block): ChatMarkdownBlock(block: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown as styled text: code spans in the small mono on the card fill; links only for the schemes a
    /// phone opens safely (web and mail), any other link is plain text.
    static func inline(_ inlines: [MarkdownInline]) -> AttributedString {
        MarkdownInlineRenderer.memoized(inlines, context: "phone-chat") { inlines in
            var text = MarkdownInlineRenderer.attributed(inlines)
            for run in text.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    text[run.range].font = TypeScale.code
                    text[run.range].backgroundColor = Fill.card
                }
                if let link = run.link, !allowsLink(link) { text[run.range].link = nil }
            }
            return text
        }
    }

    static func allowsLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

/// One text run: its paragraphs with their list markers and quote bars.
private struct ChatMarkdownRun: View {
    let run: MarkdownRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(run.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                ChatMarkdownParagraph(paragraph: paragraph).padding(.top, paragraph.spacingBefore)
            }
        }
    }
}

private struct ChatMarkdownParagraph: View {
    let paragraph: MarkdownRunParagraph

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(paragraph.levels.enumerated()), id: \.offset) { index, level in
                switch level {
                case .quote:
                    Rectangle().fill(.tertiary).frame(width: Spacing.tight).padding(.trailing, Spacing.regular)
                case let .listItem(marker):
                    Text(index >= paragraph.startsAt ? Self.marker(marker) : "")
                        .font(TypeScale.rowTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: Spacing.page, alignment: .leading)
                }
            }
            Text(ChatMarkdownView.inline(paragraph.inlines))
                .font(font)
                .foregroundStyle(paragraph.levels.contains { if case .quote = $0 { true } else { false } } ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var font: Font {
        switch paragraph.kind {
        case .body: TypeScale.rowTitle
        case let .heading(level): ChatMarkdownView.headingFont(level)
        }
    }

    static func marker(_ marker: MarkdownRunMarker) -> String {
        switch marker {
        case .bullet: "•"
        case let .number(number): "\(number)."
        case .checked: "☑"
        case .unchecked: "☐"
        }
    }
}

/// A block that keeps its own view.
private struct ChatMarkdownBlock: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .code(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(TypeScale.code).textSelection(.enabled).padding(Spacing.regular)
            }
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        case let .table(table):
            ChatMarkdownTable(table: table)
        case .rule:
            Divider()
        case let .heading(level, inlines):
            Text(ChatMarkdownView.inline(inlines)).font(ChatMarkdownView.headingFont(level))
        case let .paragraph(inlines):
            Text(ChatMarkdownView.inline(inlines)).font(TypeScale.rowTitle)
        case let .list(list):
            VStack(alignment: .leading, spacing: MarkdownRunBuilder.itemSpacing) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 0) {
                        Text(list.ordered ? "\(list.start + index)." : "•")
                            .foregroundStyle(.secondary)
                            .frame(width: Spacing.page, alignment: .leading)
                        VStack(alignment: .leading, spacing: MarkdownRunBuilder.blockSpacing) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, inner in Self(block: inner) }
                        }
                    }
                }
            }
        case let .quote(blocks):
            HStack(alignment: .top, spacing: Spacing.regular) {
                Rectangle().fill(.tertiary).frame(width: Spacing.tight)
                VStack(alignment: .leading, spacing: MarkdownRunBuilder.blockSpacing) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in Self(block: inner) }
                }
            }
        }
    }
}

/// A table that scrolls sideways (the phone only; the Mac does not change).
private struct ChatMarkdownTable: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.compact) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(ChatMarkdownView.inline(cell)).font(TypeScale.rowEmphasis)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(ChatMarkdownView.inline(cell)).font(TypeScale.rowTitle)
                        }
                    }
                }
            }
            .padding(Spacing.regular)
        }
        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}
