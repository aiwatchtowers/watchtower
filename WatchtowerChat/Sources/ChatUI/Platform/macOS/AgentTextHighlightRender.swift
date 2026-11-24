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
        var resolved = Set<String>()
        for item in found where item.span.kind == .path && !resolved.contains(item.span.text) {
            if resolvesPath(item.span.text) { resolved.insert(item.span.text) }
        }
        return memo.value(for: Key(text: text, resolvedPaths: resolved), cost: { $0.length }, build: {
            let kept = kept(found, resolved: resolved)
            return kept.isEmpty ? text : apply(kept, to: text)
        })
    }

    /// The paths that resolve, and the refs and hashes outside them: a candidate that does not resolve leaves a ref
    /// inside it coloured (`#2201/T2`). One ordered pass over both lists (`found` is in text order).
    static func kept(_ found: [Found], resolved: Set<String>) -> [Found] {
        let paths = found.filter { $0.span.kind == .path && resolved.contains($0.span.text) }
            .sorted { $0.range.location < $1.range.location }
        var next = 0
        var out = paths
        for item in found.sorted(by: { $0.range.location < $1.range.location }) where item.span.kind != .path {
            while next < paths.count, NSMaxRange(paths[next].range) <= item.range.location { next += 1 }
            let overlaps = next < paths.count && paths[next].range.location < NSMaxRange(item.range)
            if !overlaps { out.append(item) }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// What VoiceOver offers for a span, as the Workchat acts on it.
    static func accessibilityName(_ span: AgentTextHighlights.Span) -> String {
        switch span.kind {
        case .ref: "Show \(span.text) on the board"
        case .hash, .command: "Copy \(span.text)"
        case .path: "Open \(span.text)"
        }
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
/// When a click on a highlighted span runs its action (review round 1): a plain single click — no modifier, no
/// double or triple click, nothing selected — that went up on the span it went down on. Anything else is AppKit's:
/// a drag selects, a double click selects the word, a control-click opens the menu.
enum HighlightClick {
    static func fires(
        clickCount: Int, modifiers: NSEvent.ModifierFlags, selectionLength: Int, down: NSRange, up: NSRange?
    ) -> Bool {
        let held = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        return clickCount == 1 && held.isEmpty && selectionLength == 0 && up == down
    }
}
#endif
