import Foundation

/// Converts the same markdown subset `MarkdownText` renders (headers, bullet /
/// numbered lists, blockquotes, code blocks, dividers, inline bold/italic/code/
/// links) into HTML for the pasteboard, so pasting into rich-text targets
/// (Slack, Mail, Notes) keeps the formatting. A deliberate render/export
/// dual-path with `MarkdownText` — extend both when the subset grows.
enum MarkdownToHTML {
    static func convert(_ markdown: String) -> String {
        var html: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
            } else if trimmed.hasPrefix("```") {
                html.append(codeBlock(lines: lines, index: &i))
            } else if let (level, content) = header(trimmed) {
                html.append("<h\(level)>\(inline(content))</h\(level)>")
                i += 1
            } else if ["---", "***", "___"].contains(trimmed) {
                html.append("<hr>")
                i += 1
            } else if trimmed.hasPrefix("> ") {
                html.append(blockquote(lines: lines, index: &i))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                html.append(list(lines: lines, index: &i, tag: "ul", isItem: isBulletItem, content: bulletContent))
            } else if isNumberedItem(trimmed) {
                html.append(list(lines: lines, index: &i, tag: "ol", isItem: isNumberedItem, content: numberedContent))
            } else {
                html.append(paragraph(lines: lines, index: &i))
            }
        }

        return html.joined(separator: "\n")
    }

    // MARK: - Blocks

    private static func codeBlock(lines: [String], index i: inout Int) -> String {
        var code: [String] = []
        i += 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                i += 1
                break
            }
            code.append(lines[i])
            i += 1
        }
        return "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>"
    }

    private static func blockquote(lines: [String], index i: inout Int) -> String {
        var quote: [String] = []
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("> ") else { break }
            quote.append(String(line.dropFirst(2)))
            i += 1
        }
        return "<blockquote>\(inline(quote.joined(separator: "\n")))</blockquote>"
    }

    private static func list(
        lines: [String], index i: inout Int, tag: String,
        isItem: (String) -> Bool, content: (String) -> String
    ) -> String {
        var items: [String] = []
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if isItem(line) {
                items.append(content(line))
            } else if line.isEmpty {
                break
            } else if !items.isEmpty && !isBlockStart(line) {
                // Wrapped continuation of the previous item.
                items[items.count - 1] += " " + line
            } else {
                break
            }
            i += 1
        }
        let body = items.map { "<li>\(inline($0))</li>" }.joined()
        return "<\(tag)>\(body)</\(tag)>"
    }

    private static func paragraph(lines: [String], index i: inout Int) -> String {
        var para: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isBlockStart(trimmed) { break }
            para.append(trimmed)
            i += 1
        }
        return "<p>\(inline(para.joined(separator: "\n")))</p>"
    }

    // MARK: - Line classification

    private static func header(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return (level, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func isBulletItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func bulletContent(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    private static func isNumberedItem(_ line: String) -> Bool {
        guard let first = line.first, first.isNumber else { return false }
        var i = line.startIndex
        while i < line.endIndex && line[i].isNumber { i = line.index(after: i) }
        guard i < line.endIndex, line[i] == "." || line[i] == ")" else { return false }
        let after = line.index(after: i)
        return after < line.endIndex && line[after] == " "
    }

    private static func numberedContent(_ line: String) -> String {
        guard let sep = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return line }
        let after = line.index(after: sep)
        guard after < line.endIndex else { return "" }
        return String(line[after...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isBlockStart(_ line: String) -> Bool {
        if line.hasPrefix("```") { return true }
        if header(line) != nil { return true }
        if isBulletItem(line) || isNumberedItem(line) { return true }
        if line.hasPrefix("> ") { return true }
        if ["---", "***", "___"].contains(line) { return true }
        return false
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = s.replacingOccurrences(
            of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\*([^*\s][^*]*)\*"#, with: "<em>$1</em>", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#,
            with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n", with: "<br>")
        return s
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
