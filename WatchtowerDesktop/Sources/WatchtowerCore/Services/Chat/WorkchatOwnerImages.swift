import Foundation

/// An owner's Workchat line as its bubble shows it: each image path in it reads `[Image #N]`, as the paste token did
/// in the field. A pasted image goes to the agent as its saved file's path (`WorkchatOutgoing.quoted`, in place of
/// its `[Image #N]` token), a dropped image file as its path on a line of its own; what was sent, the feed's entry and
/// the echo match are untouched. Text only: no file is looked at, so no folder asks for permission.
///
/// A path counts when it is absolute, ends in an image extension and stands as a whole token (bare, or in double
/// quotes with `\"` and `\\` escaped; punctuation around it is the owner's text), and either lies in a
/// `workchat-attachments` folder (a paste, inline or on its own line) or stands on a line of its own (a dropped or
/// picked image anywhere else). Any other image path — one named mid-sentence elsewhere — is the owner's prose and
/// stays as written. The images are numbered from 1 in order of first appearance, a path named twice keeping its
/// number.
package enum WorkchatOwnerImages {
    package static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic"]

    /// `text` with its image paths shown as `[Image #N]`, and a line that is only an image marker (Go's `[image]`,
    /// Claude Code's `[Image #N]`) dropped when an image stands for it. Unchanged when no image was found. For
    /// Markdown (`markdown`, the feed's bubble) a label that opens a line before a colon is escaped (`\[Image #1]:`),
    /// so it is not read as a link definition and lost.
    package static func shown(_ text: String, markdown: Bool = false) -> String {
        guard text.contains("/") else { return text }
        var numbers: [String: Int] = [:]
        var lines: [(text: String, labelled: Bool)] = []
        // A line ending in `\r\n` stands alone the same as one ending in `\n`.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let tokens = pathTokens(in: line)
            let alone = tokens.count == 1 && tokens[0].raw == line.trimmingCharacters(in: .whitespaces)
            let found = tokens.filter { isImage($0.path, alone: alone) }
            guard !found.isEmpty else {
                lines.append((line, false))
                continue
            }
            for token in found where numbers[token.path] == nil { numbers[token.path] = numbers.count + 1 }
            var kept = line
            for (index, token) in found.enumerated().reversed() {
                // Paths glued end to end (an older build sent two pastes with no space) read as two labels.
                let glued = index + 1 < found.count && found[index + 1].range.lowerBound == token.range.upperBound
                kept.replaceSubrange(token.range, with: "[Image #\(numbers[token.path] ?? 0)]" + (glued ? " " : ""))
            }
            if markdown, kept.drop(while: \.isWhitespace).hasPrefix("[Image #"),
               let close = kept.firstIndex(of: "]"), kept[close...].dropFirst().first == ":" {
                kept.insert("\\", at: kept.firstIndex(of: "[") ?? kept.startIndex)
            }
            lines.append((kept, true))
        }
        guard !numbers.isEmpty else { return text }
        lines.removeAll { !$0.labelled && WorkchatOutgoing.isImageMarker($0.text.trimmingCharacters(in: .whitespaces)) }
        return lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isImage(_ path: String, alone: Bool) -> Bool {
        guard path.hasPrefix("/"),
              imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        return alone || path.contains("/workchat-attachments/")
    }

    private struct Token {
        let range: Range<String.Index>
        let raw: Substring
        let path: String
    }

    /// Punctuation that may open before a path and stays text: `(/…/a.png)`.
    private static let openers: Set<Character> = ["(", "[", "{"]
    /// What a path may start right after, mid-word too: an opening bracket or a quote, as `PasteTokens.expand`
    /// leaves a pasted path touching it (`compare([Image #1])` is sent as `compare(/…/a.png)`).
    private static let leads: Set<Character> = ["(", "[", "{", "\"", "'"]
    /// Punctuation that may close after a path and stays text: `see /…/a.png.`, `"/…/a b.png",`, `'/…/a.png'`.
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'"]

    /// The whole-token absolute paths of one line: bare (`/…` up to whitespace, closing punctuation left out) or
    /// double-quoted with `\"` and `\\` escaped (`"/…"` followed by whitespace, closing punctuation or the end), each
    /// starting the line, after whitespace or right after an opening bracket or quote (`leads`), past any opening
    /// bracket.
    private static func pathTokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            let atBoundary = index == line.startIndex
                || line[line.index(before: index)].isWhitespace || leads.contains(line[line.index(before: index)])
            guard atBoundary else {
                index = line.index(after: index)
                continue
            }
            let start = line[index...].firstIndex { !openers.contains($0) } ?? line.endIndex
            let found = start == line.endIndex ? []
                : quotedToken(in: line, at: start).map { [$0] } ?? bareTokens(in: line, at: start)
            if let last = found.last {
                tokens += found
                index = last.range.upperBound
            } else {
                index = line.index(after: index)
            }
        }
        return tokens
    }

    /// `index` ends a token: the end or whitespace, once any closing punctuation is skipped.
    private static func endsToken(_ line: String, at index: String.Index) -> Bool {
        let rest = line[index...].drop { closers.contains($0) }
        return rest.first.map(\.isWhitespace) ?? true
    }

    /// A bare path, or several glued end to end (`/…/a-1.png/…/a-2.png`, two pastes sent with no space between them
    /// by an older build): split after each image extension a `/` follows.
    private static func bareTokens(in line: String, at start: String.Index) -> [Token] {
        guard line[start] == "/" else { return [] }
        var end = line[start...].firstIndex(where: \.isWhitespace) ?? line.endIndex
        while end > line.index(after: start), closers.contains(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        var tokens: [Token] = []
        var from = start
        let word = NSRange(start..<end, in: line)
        for match in gluedImageEnd?.matches(in: line, range: word) ?? [] {
            guard let cut = Range(match.range, in: line)?.upperBound else { continue }
            tokens.append(Token(range: from..<cut, raw: line[from..<cut], path: String(line[from..<cut])))
            from = cut
        }
        tokens.append(Token(range: from..<end, raw: line[from..<end], path: String(line[from..<end])))
        return tokens
    }

    /// An image extension a `/` follows: where one glued path ends and the next begins.
    private static let gluedImageEnd = try? NSRegularExpression(
        pattern: "\\.(?:" + imageExtensions.sorted().joined(separator: "|") + ")(?=/)", options: .caseInsensitive
    )

    private static func quotedToken(in line: String, at start: String.Index) -> Token? {
        guard line[start] == "\"" else { return nil }
        var index = line.index(after: start)
        guard index < line.endIndex, line[index] == "/" else { return nil }
        var path = ""
        while index < line.endIndex {
            let char = line[index]
            let next = line.index(after: index)
            if char == "\\", next < line.endIndex, line[next] == "\"" || line[next] == "\\" {
                path.append(line[next])
                index = line.index(after: next)
                continue
            }
            if char == "\"" {
                guard endsToken(line, at: next) else { return nil }
                return Token(range: start..<next, raw: line[start..<next], path: path)
            }
            path.append(char)
            index = next
        }
        return nil
    }
}
