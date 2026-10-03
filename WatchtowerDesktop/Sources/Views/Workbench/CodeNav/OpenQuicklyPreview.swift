import AppKit
import SwiftUI
import WatchtowerCore

/// Open Quickly's right pane (spec §8.1): the selected row's kind and name,
/// `container › path:line`, the doc comment and its code — the first 12
/// lines from the symbol (or of the file), or the 3 lines around a text
/// match — in the editor theme's colours.
struct OpenQuicklyPreviewPane: View {
    let session: OpenQuicklySession
    let row: OpenQuicklyRow?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row {
                header(row)
                code(row)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: row?.id) { await loadLines(row) }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ row: OpenQuicklyRow) -> some View {
        switch row {
        case let .match(result):
            switch result.item {
            case let .symbol(symbol):
                HStack(spacing: 6) {
                    CodeKindBadge(kind: symbol.kind)
                    Text(symbol.name).font(.headline).lineLimit(1)
                }
                location(symbol.container.isEmpty ? "\(symbol.path):\(symbol.line)" : "\(symbol.container) › \(symbol.path):\(symbol.line)")
                if !symbol.doc.isEmpty {
                    Text(symbol.doc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case let .file(path):
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: session.project.folderURL.appendingPathComponent(path).path))
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(result.title).font(.headline).lineLimit(1)
                }
                location(path)
            }
        case let .text(match):
            location("\(match.path):\(match.line)")
        case .moreText, .askAI:
            EmptyView()
        }
    }

    private func location(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
    }

    // MARK: Code

    @ViewBuilder
    private func code(_ row: OpenQuicklyRow) -> some View {
        switch row {
        case let .text(match):
            codeBlock(OpenQuicklyPreviewText.around(match), path: match.path, highlight: (match.line, match.textCol))
        case .match:
            if let target = row.target {
                let preview = session.previews[OpenQuicklySession.previewKey(path: target.path, line: target.line ?? 1)]
                if let error = preview?.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else if let lines = preview?.lines {
                    codeBlock(lines, path: target.path, highlight: nil)
                }
            }
        case .moreText, .askAI:
            EmptyView()
        }
    }

    private func codeBlock(_ lines: [OpenQuicklyPreviewLine], path: String, highlight: (line: Int, col: Int)?) -> some View {
        let palette = CodeThemeColors.palette(colorScheme)
        let hash = CodePreviewHighlighter.usesHashComments(path: path)
        let width = String(lines.last?.number ?? 0).count
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(lines, id: \.number) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(line.number).leftPadded(to: width))
                        .foregroundStyle(.secondary)
                    Text(coloured(line.text, palette: palette, hash: hash, match: highlight?.line == line.number ? highlight?.col : nil))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeThemeColors.color(rgb: palette.background), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    /// One line in the theme's colours; a text match's query bold in the
    /// string colour.
    private func coloured(_ text: String, palette: CodeThemePalette, hash: Bool, match col: Int?) -> AttributedString {
        let shown = text
        var out = AttributedString(shown)
        out.foregroundColor = CodeThemeColors.color(rgb: palette.foreground)
        for token in CodePreviewHighlighter.tokens(shown, hashComments: hash) {
            if let range = Self.range(token.range, in: shown, of: out) {
                out[range].foregroundColor = CodeThemeColors.color(rgb: palette.rgb(token.role))
            }
        }
        if let col {
            let length = session.model.trimmedQuery.utf16.count
            if length > 0, let range = Self.range((col - 1) ..< (col - 1 + length), in: shown, of: out) {
                out[range].foregroundColor = CodeThemeColors.color(rgb: palette.rgb(.string))
                out[range].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return out
    }

    private static func range(_ offsets: Range<Int>, in text: String, of attributed: AttributedString) -> Range<AttributedString.Index>? {
        let utf16 = text.utf16
        guard offsets.lowerBound >= 0, offsets.upperBound <= utf16.count, !offsets.isEmpty else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: offsets.lowerBound)
        let upper = utf16.index(utf16.startIndex, offsetBy: offsets.upperBound)
        guard let from = AttributedString.Index(lower, within: attributed),
              let to = AttributedString.Index(upper, within: attributed) else { return nil }
        return from ..< to
    }

    private func loadLines(_ row: OpenQuicklyRow?) async {
        guard case .match? = row, let target = row?.target else { return }
        await session.loadPreview(path: target.path, line: target.line ?? 1)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
