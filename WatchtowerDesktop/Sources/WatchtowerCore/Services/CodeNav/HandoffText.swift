import Foundation

/// What "Hand to Claude Code" (⌥⌘↩, spec 2026-10-02 §9.5) types into a
/// workbench session or starts a new one with: the fixed first line, where
/// the question was asked, each owner question with its completed answer,
/// and the `path:line` references the answers cite. Built from the stored
/// messages only: system notices, a reply still streaming (`partial`) and a
/// failed one are left out, and no file body is ever added — the selection's
/// code stays in the editor (Claude Code reads the files itself); a fenced
/// block inside an answer is the answer's own text. Pure.
package enum HandoffText {
    package static let header = "From a Watchtower code question:"

    /// nil when the conversation holds no owner question yet.
    package static func conversation(origin: CodeQuestionOrigin, messages: [ChatMessageRecord]) -> String? {
        var turns: [(question: String, answer: String?)] = []
        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case "user" where !text.isEmpty:
                turns.append((text, nil))
            case "assistant" where message.status == "complete" && !text.isEmpty && !turns.isEmpty:
                let last = turns.count - 1
                turns[last].answer = [turns[last].answer, text].compactMap(\.self).joined(separator: "\n\n")
            default:
                continue
            }
        }
        guard !turns.isEmpty else { return nil }
        // Over `maxBytes` the earliest turns go first (ruling R54c); a last
        // turn still too long is cut.
        var kept = turns[...]
        var text = render(origin: origin, turns: kept, omitted: false)
        while text.utf8.count > maxBytes, kept.count > 1 {
            kept = kept.dropFirst()
            text = render(origin: origin, turns: kept, omitted: true)
        }
        return cut(text)
    }

    /// The cap on a hand-off, in UTF-8 bytes.
    package static let maxBytes = 32 * 1024
    package static let omittedLine = "… earlier turns omitted"
    package static let cutLine = "… cut at 32 KB"

    private static func render(
        origin: CodeQuestionOrigin, turns: ArraySlice<(question: String, answer: String?)>, omitted: Bool
    ) -> String {
        var blocks = [heading(origin)]
        if omitted { blocks.append(omittedLine) }
        for turn in turns {
            blocks.append("Question: \(turn.question)")
            if let answer = turn.answer { blocks.append("Answer:\n\(answer)") }
        }
        // Where it was asked first, then what the answers cite; none cited,
        // the "Asked at" line already says it all.
        let cited = turns.flatMap { citations(in: $0.answer ?? "") }
        if !cited.isEmpty {
            var references = origin.path.isEmpty ? [] : [location(origin)]
            for citation in cited where !references.contains(citation) {
                references.append(citation)
            }
            blocks.append("References: " + references.joined(separator: ", "))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// `text` within `maxBytes`, cut on a character boundary.
    private static func cut(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let budget = maxBytes - cutLine.utf8.count - 2
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard bytes + size <= budget else { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end]) + "\n\n" + cutLine
    }

    /// Open Quickly's ⌥⌘↩: the query, asked about the Files pane's open
    /// file at its cursor line. nil for an empty query.
    package static func query(_ query: String, origin: CodeQuestionOrigin) -> String? {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return nil }
        return cut([heading(origin), "Question: \(question)"].joined(separator: "\n\n"))
    }

    // MARK: - Private

    /// The header and where the question was asked, one line each.
    private static func heading(_ origin: CodeQuestionOrigin) -> String {
        header + "\n" + (origin.path.isEmpty ? "Asked with no file open" : "Asked at \(location(origin))")
    }

    /// `path:line`, or `path:start-end` for a selection over several lines.
    private static func location(_ origin: CodeQuestionOrigin) -> String {
        guard let selection = origin.selection, selection.endLine > selection.startLine else {
            return "\(origin.path):\(origin.line)"
        }
        return "\(origin.path):\(selection.startLine)-\(selection.endLine)"
    }

    /// A code link: groups 1 its text, 2 its URL.
    private static let codeLink = try? NSRegularExpression(
        pattern: #"\[`?([^\]`]*)`?\]\(("# + NSRegularExpression.escapedPattern(for: CodeLineLinks.scheme) + #"://[^)\s]*)\)"#)

    /// The `path:line` citations of an answer, in order, by
    /// `CodeLineLinks`' own rules (fenced code and URLs are not citations).
    /// Each is read off the link's URL; a citation's own text is kept when it
    /// names that file, so a range or a column stays as written, while a
    /// link's text ("the plan", a folder-less name) never stands in for it.
    private static func citations(in answer: String) -> [String] {
        let linked = CodeLineLinks.linkified(answer) as NSString
        let range = NSRange(location: 0, length: linked.length)
        return (codeLink?.matches(in: linked as String, range: range) ?? []).compactMap { match in
            guard let url = URL(string: linked.substring(with: match.range(at: 2))),
                  let target = CodeLineLinks.target(from: url), let line = target.line else { return nil }
            let text = linked.substring(with: match.range(at: 1))
            if text.hasPrefix(target.path + ":") { return text }
            return "\(target.path):\(line)" + (target.col.map { ":\($0)" } ?? "")
        }
    }
}
