import Foundation

/// The suggested change in a code answer (spec 2026-10-02 §9.1, §9.2): a
/// "Suggest a change" reply ends with one fenced block tagged `wt-edit`
/// holding the replacement for the selection only. Only the first complete
/// block counts; a block still open (the reply is streaming) is none.
package enum WtEditBlock {
    package static let tag = "wt-edit"

    /// The replacement in `reply`, or nil when it has no complete block.
    package static func replacement(in reply: String) -> String? {
        let lines = reply.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard let fence = openingFence(lines[index]) else {
                index += 1
                continue
            }
            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count {
                if closes(lines[cursor], fence: fence) { return body.joined(separator: "\n") }
                body.append(lines[cursor])
                cursor += 1
            }
            return nil
        }
        return nil
    }

    /// A fenced block drops the line break before its closing fence: when
    /// the replaced text ended with one, the replacement gets it back, so
    /// the next line is never joined onto it.
    package static func fitted(_ replacement: String, toReplace original: String) -> String {
        guard !replacement.hasSuffix("\n") else { return replacement }
        if original.hasSuffix("\r\n") { return replacement + "\r\n" }
        if original.hasSuffix("\n") { return replacement + "\n" }
        return replacement
    }

    /// The backtick run of a `wt-edit` opening line (up to three spaces of
    /// indent, then ≥ 3 backticks, then the tag as the first word).
    private static func openingFence(_ line: String) -> Int? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let run = rest.prefix { $0 == "`" }.count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        let word = info.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return word == tag ? run : nil
    }

    /// A closing line: only a backtick run at least as long as the opening.
    private static func closes(_ line: String, fence: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " }.count
        return indent <= 3 && trimmed.count >= fence && trimmed.allSatisfy { $0 == "`" }
    }
}
