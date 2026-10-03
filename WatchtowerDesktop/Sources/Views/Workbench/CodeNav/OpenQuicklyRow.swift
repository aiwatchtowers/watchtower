import AppKit
import SwiftUI
import WatchtowerCore

/// One row of Open Quickly's results (spec §8.1): a kind badge or the
/// Finder icon, the name with its matched characters bold, and a subtitle —
/// container · file for a symbol, folder and git mark for a file,
/// path:line for a text match.
struct OpenQuicklyRowView: View {
    let row: OpenQuicklyRow
    let isSelected: Bool
    let query: String
    let folder: URL
    let gitStatuses: [String: GitFileStatus]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case let .match(result):
            switch result.item {
            case let .file(path):
                fileIcon(path)
                titled(OpenQuicklyHighlight.bold(result.title, at: result.titleMatches), subtitle: folderSubtitle(path))
                if let status = gitStatuses[path] {
                    Text(status.letter).font(.caption2.monospaced()).foregroundStyle(GitMark.color(status))
                }
            case let .symbol(symbol):
                CodeKindBadge(kind: symbol.kind)
                titled(OpenQuicklyHighlight.bold(result.title, at: result.titleMatches), subtitle: symbolSubtitle(symbol))
            }
        case let .text(match):
            fileIcon(match.path)
            titled(textTitle(match), subtitle: "\(match.path):\(match.line)")
        case .moreText, .askAI:
            Text(row.label ?? "")
                .font(.callout)
                .foregroundStyle(row == .askAI(query: query) ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
    }

    private func fileIcon(_ path: String) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.appendingPathComponent(path).path))
            .resizable()
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private func titled(_ title: AttributedString, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
    }

    private func folderSubtitle(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "./" : folder
    }

    private func symbolSubtitle(_ symbol: CodeSymbol) -> String {
        let file = (symbol.path as NSString).lastPathComponent
        return symbol.container.isEmpty ? file : "\(symbol.container) · \(file)"
    }

    /// The matched line, its match bold in the theme's string colour.
    private func textTitle(_ match: CodeSearchMatch) -> AttributedString {
        let trimmed = match.text.drop { $0 == " " || $0 == "\t" }
        let dropped = match.text.utf16.count - trimmed.utf16.count
        let start = match.textCol - 1 - dropped
        let length = query.trimmingCharacters(in: .whitespaces).utf16.count
        let range = start >= 0 ? Array(start ..< start + length) : []
        return OpenQuicklyHighlight.bold(
            String(trimmed), at: range, color: CodeThemeColors.color(.string, scheme: colorScheme)
        )
    }
}

/// Bold runs at UTF-16 offsets of a string.
enum OpenQuicklyHighlight {
    static func bold(_ text: String, at offsets: [Int], color: Color? = nil) -> AttributedString {
        var out = AttributedString(text)
        let utf16 = text.utf16
        for offset in Set(offsets) where offset >= 0 && offset < utf16.count {
            let lower = utf16.index(utf16.startIndex, offsetBy: offset)
            let upper = utf16.index(after: lower)
            guard let from = AttributedString.Index(lower, within: out),
                  let to = AttributedString.Index(upper, within: out) else { continue }
            out[from ..< to].inlinePresentationIntent = .stronglyEmphasized
            if let color { out[from ..< to].foregroundColor = color }
        }
        return out
    }
}
