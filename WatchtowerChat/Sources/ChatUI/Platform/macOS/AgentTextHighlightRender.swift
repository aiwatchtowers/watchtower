#if os(macOS)
import AppKit
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

extension NSAttributedString.Key {
    /// Inline code in a run (`MarkdownRunText.appendInlines`): highlighting reads only a command there.
    static let markdownInlineCode = NSAttributedString.Key("watchtower.markdownInlineCode")
    /// A highlighted span of the agent's text (`AgentTextHighlightBox`): a click opens it.
    static let agentHighlight = NSAttributedString.Key("watchtower.agentHighlight")
}

/// A highlighted span as an attribute value, equal by the span (so a rebuilt run's text equals the shown one).
final class AgentTextHighlightBox: NSObject {
    let span: AgentTextHighlights.Span

    init(_ span: AgentTextHighlights.Span) {
        self.span = span
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? AgentTextHighlightBox)?.span == span
    }

    override var hash: Int { span.text.hashValue }
}

/// A finished run of the agent's text with its refs, hashes, paths and commands in their `SyntaxTint` (spec
/// 2026-11-24-workchat-polish §2, D3): the foreground colour only — no background, no weight. Plain text is scanned
/// with `AgentTextHighlights.spans(inPlain:)`, inline code only for a command, links never (code blocks are not in a
/// run). A path keeps its colour only when `resolvesPath` says it is a file of the session's folders. Memoised: the
/// scan per run, the coloured text per run and set of resolved paths.
@MainActor
enum AgentTextHighlightRender {
    struct Found {
        let range: NSRange
        let span: AgentTextHighlights.Span
    }

    private struct Key: Hashable {
        let text: NSAttributedString
        let resolvedPaths: Set<String>
    }

    private static let scans = MarkdownMemo<NSAttributedString, [Found]>(totalCostLimit: 1 << 16)
    private static let memo = MarkdownMemo<Key, NSAttributedString>(totalCostLimit: 4 << 20)

    static func highlighted(_ text: NSAttributedString, resolvesPath: (String) -> Bool) -> NSAttributedString {
        let found = scans.value(for: text, cost: { max($0.count, 1) }, build: { scan(text) })
        let kept = found.filter { $0.span.kind != .path || resolvesPath($0.span.text) }
        guard !kept.isEmpty else { return text }
        let paths = Set(kept.filter { $0.span.kind == .path }.map(\.span.text))
        return memo.value(for: Key(text: text, resolvedPaths: paths), cost: { $0.length },
                          build: { apply(kept, to: text) })
    }

    static func color(_ kind: AgentTextHighlights.Kind) -> NSColor {
        switch kind {
        case .ref: NSColor(SyntaxTint.ref)
        case .hash: NSColor(SyntaxTint.hash)
        case .path: NSColor(SyntaxTint.path)
        case .command: NSColor(SyntaxTint.command)
        }
    }

    /// Every candidate span of the run, links left out.
    static func scan(_ text: NSAttributedString) -> [Found] {
        let string = text.string as NSString
        return stretches(text).flatMap { range, isCode -> [Found] in
            let piece = string.substring(with: range)
            let spans = isCode
                ? AgentTextHighlights.commandSpan(inCode: piece).map { [$0] } ?? []
                : AgentTextHighlights.spans(inPlain: piece)
            return spans.map { span in
                let local = NSRange(span.range, in: piece)
                return Found(range: NSRange(location: range.location + local.location, length: local.length), span: span)
            }
        }
    }

    /// The run's plain and inline-code stretches, links left out. Neighbouring plain pieces join (a word in italics
    /// inside a path); each inline code stays its own.
    private static func stretches(_ text: NSAttributedString) -> [(range: NSRange, isCode: Bool)] {
        var out: [(range: NSRange, isCode: Bool)] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard attributes[.link] == nil else { return }
            let isCode = attributes[.markdownInlineCode] != nil
            if !isCode, let last = out.last, !last.isCode, NSMaxRange(last.range) == range.location {
                out[out.count - 1].range.length += range.length
            } else {
                out.append((range, isCode))
            }
        }
        return out
    }

    private static func apply(_ found: [Found], to text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        for item in found {
            out.addAttributes([.foregroundColor: color(item.span.kind), .agentHighlight: AgentTextHighlightBox(item.span)],
                              range: item.range)
        }
        return out
    }
}
#endif
