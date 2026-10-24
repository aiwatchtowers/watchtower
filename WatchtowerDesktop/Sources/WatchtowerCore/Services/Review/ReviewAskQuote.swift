import Foundation

/// Ask agent's quote (board #962, spec §4): what Branch review puts at the
/// top of the session's Workchat draft — the selected lines of a file, or a
/// risk the AI overview flags. The owner then types the question and sends
/// it as any Workchat line.
package enum ReviewAskQuote {
    /// A longer selection is cut after this many lines, then a `…` line.
    package static let maxLines = 40

    /// ``Re `path:31–34`:`` (` (old side)` for removed lines), then the lines
    /// in a fenced block with no language, longer than any backtick run in them.
    package static func code(path: String, side: String, startLine: Int, endLine: Int, lines: [String]) -> String {
        let range = startLine == endLine ? "\(startLine)" : "\(startLine)–\(endLine)"
        let header = "Re `\(path):\(range)`" + (side == "old" ? " (old side)" : "") + ":"
        var body = Array(lines.prefix(maxLines))
        if lines.count > maxLines { body.append("…") }
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: body) + 1))
        return ([header, fence] + body + [fence]).joined(separator: "\n")
    }

    /// The read-only preview's Ask (the code viewer page's "Ask AI" item and
    /// ⌘I): the selected lines of a current file, which has no diff side, so
    /// the quote is unmarked like the new side's. A selection ending at
    /// column 1 of a later line does not take that line; an empty one quotes
    /// the cursor's line.
    package static func current(path: String, text: String, startLine: Int, endLine: Int, endCol: Int) -> String {
        let last = endLine > startLine && endCol <= 1 ? endLine - 1 : endLine
        return code(path: path, side: "new", startLine: startLine, endLine: last,
                    lines: lines(of: text, startLine: startLine, endLine: last))
    }

    /// A risk of the AI overview: the file and why, no code.
    package static func risk(path: String, level: String, why: String) -> String {
        "Re `\(path)` — the AI overview flags a \(level) risk: \(why)"
    }

    /// Lines `startLine...endLine` (1-based) of `text`, clamped to the text.
    package static func lines(of text: String, startLine: Int, endLine: Int) -> [String] {
        let all = text.components(separatedBy: "\n")
        let from = max(startLine, 1) - 1
        let to = min(endLine, all.count)
        guard from < to else { return [] }
        return Array(all[from..<to])
    }

    /// The quote over the owner's draft, a blank line between them.
    package static func prepend(_ quote: String, to draft: String) -> String {
        quote + "\n\n" + draft
    }

    private static func longestBacktickRun(in lines: [String]) -> Int {
        var longest = 0
        for line in lines {
            var run = 0
            for char in line {
                run = char == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
    }
}
