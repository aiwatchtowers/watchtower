#if os(iOS)
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The phone's answer text (iPhone chat spec §6.2): the shared parse and run builder (`MarkdownDocument`,
/// `MarkdownRunBuilder`, the Mac's), drawn in SwiftUI — headings, lists, quotes and inline styles as text runs; code
/// blocks, tables and rules as their own views. Code and tables scroll sideways.
struct ChatAnswerText: View {
    let text: String
    let isFinal: Bool
    let isOwner: Bool
    /// The phone keeps the agent's text plain (spec 2026-11-24-workchat-polish C2).
    var highlighting: AgentTextHighlighting?

    var body: some View {
        if isOwner {
            Text(text).font(.callout).textSelection(.enabled)
        } else {
            MarkdownRuns(text: text)
        }
    }
}

/// An answer's Markdown as SwiftUI runs.
public struct MarkdownRuns: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        let segments = MarkdownRunBuilder.segments(MarkdownDocument.parse(text))
        VStack(alignment: .leading, spacing: MarkdownRunBuilder.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .textRun(run): MarkdownRunView(run: run)
                case let .block(block): MarkdownBlockRun(block: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let codeFont = Font.caption.monospaced()

    /// Inline Markdown as styled text: code spans in the small mono on the card fill; links only for the schemes a
    /// phone opens safely (web and mail), any other link is plain text.
    static func inline(_ inlines: [MarkdownInline]) -> AttributedString {
        MarkdownInlineRenderer.memoized(inlines, context: "phone-chat") { inlines in
            var text = MarkdownInlineRenderer.attributed(inlines)
            for run in text.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    text[run.range].font = codeFont
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
private struct MarkdownRunView: View {
    let run: MarkdownRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(run.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                MarkdownParagraphView(paragraph: paragraph).padding(.top, paragraph.spacingBefore)
            }
        }
    }
}

private struct MarkdownParagraphView: View {
    let paragraph: MarkdownRunParagraph

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(paragraph.levels.enumerated()), id: \.offset) { index, level in
                switch level {
                case .quote:
                    Rectangle().fill(.tertiary).frame(width: Spacing.tight).padding(.trailing, Spacing.regular)
                case let .listItem(marker):
                    Text(index >= paragraph.startsAt ? Self.marker(marker) : "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: Spacing.page, alignment: .leading)
                }
            }
            Text(MarkdownRuns.inline(paragraph.inlines))
                .font(font)
                .foregroundStyle(paragraph.levels.contains { if case .quote = $0 { true } else { false } } ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var font: Font {
        switch paragraph.kind {
        case .body: .callout
        case let .heading(level): MarkdownRuns.headingFont(level)
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
private struct MarkdownBlockRun: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .code(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(MarkdownRuns.codeFont).textSelection(.enabled).padding(Spacing.regular)
            }
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        case let .table(table):
            ScrollingTable(table: table)
        case .rule:
            Divider()
        case let .heading(level, inlines):
            Text(MarkdownRuns.inline(inlines)).font(MarkdownRuns.headingFont(level))
        case let .paragraph(inlines):
            Text(MarkdownRuns.inline(inlines)).font(.callout)
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
#endif
