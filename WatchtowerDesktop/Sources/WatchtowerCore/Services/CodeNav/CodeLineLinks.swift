import Foundation

/// `path:line` citations in a code answer (spec 2026-10-02 §9.2) as links
/// that open the file in the Files pane: an inline code span holding only a
/// citation, or a bare one in prose, becomes a markdown link to
/// `watchtower-code://open?path=…&line=…[&col=…]`; so does an existing
/// link whose target is such a path (`[plan](docs/plan.md)`,
/// `[run](cmd/run.go:40)`, `[x](a.go#L12)`; line 1 when none is given).
/// Fenced code, URLs, images and other links are left alone. A path is
/// relative to the workbench folder and needs a folder or an extension
/// (`main.go:7`, `cmd/run:3`).
package enum CodeLineLinks {
    package static let scheme = "watchtower-code"

    private static let path = #"(?:[\w.+-]+/)+[\w.+-]+|[\w+-][\w.+-]*\.[A-Za-z0-9_+-]+"#
    private static let suffix = #":(\d+)(?:-\d+)?(?::(\d+))?"#
    // swiftlint:disable force_try
    /// A whole inline code span that is a citation.
    private static let spanCitation = try! NSRegularExpression(pattern: "^(\(path))\(suffix)$")
    /// A citation in prose: not inside a word, a path, a URL's host:port,
    /// a mail address or an existing link.
    private static let bareCitation = try! NSRegularExpression(
        pattern: #"(?<![\w/.:@\[-])(?<!\]\()("# + path + ")" + suffix + #"(?![\w/])"#)
    /// An existing markdown link (or image): its text and target stay as
    /// written, so no citation inside becomes a link within a link.
    private static let existingLink = try! NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    /// An existing link's text and target (not an image's).
    private static let linkParts = try! NSRegularExpression(pattern: #"^\[([^\]\n]*)\]\(\s*([^)\s]+)\s*\)$"#)
    /// A link target that is a path: groups 1 path, 2 line, 3 column, 4 a `#L` line.
    private static let pathTarget = try! NSRegularExpression(pattern: "^(\(path))(?:\(suffix)|#L(\\d+)(?:-L?\\d+)?)?$")
    // swiftlint:enable force_try

    /// `markdown` with its citations linked.
    package static func linkified(_ markdown: String) -> String {
        var fence: (char: Character, count: Int)?
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop { $0 == " " }
            let marker = trimmed.first
            if marker == "`" || marker == "~", let char = marker {
                let run = trimmed.prefix { $0 == char }.count
                if let open = fence {
                    if open.char == char, run >= open.count, trimmed.allSatisfy({ $0 == char || $0 == " " || $0 == "\r" }) {
                        fence = nil
                    }
                    return line
                }
                if run >= 3, line.count - trimmed.count <= 3 {
                    fence = (char, run)
                    return line
                }
            }
            return fence == nil ? linkifiedLine(line) : line
        }
        return lines.joined(separator: "\n")
    }

    /// The link for one citation.
    package static func url(path: String, line: Int, col: Int?) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "line", value: String(line))]
            + (col.map { [URLQueryItem(name: "col", value: String($0))] } ?? [])
        return components.string ?? "\(scheme)://open"
    }

    /// The file and line a link names; nil for another scheme or a path
    /// that is absolute or climbs out of the workbench folder.
    package static func target(from url: URL) -> OpenQuicklyTarget? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let path = value("path"), !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."),
              let line = value("line").flatMap(Int.init), line >= 1 else { return nil }
        return OpenQuicklyTarget(path: path, line: line, col: value("col").flatMap(Int.init))
    }

    // MARK: - One line

    /// Code spans and prose of one line, each linked its own way; an
    /// existing link is copied as it is.
    private static func linkifiedLine(_ line: String) -> String {
        let links = existingLink.matches(in: line, range: NSRange(line.startIndex..., in: line))
            .compactMap { Range($0.range, in: line) }
        var out = ""
        var prose = ""
        var index = line.startIndex
        while index < line.endIndex {
            if let link = links.first(where: { $0.lowerBound == index }) {
                out += linkedProse(prose) + relinked(String(line[link]))
                prose = ""
                index = link.upperBound
                continue
            }
            guard line[index] == "`" else {
                prose.append(line[index])
                index = line.index(after: index)
                continue
            }
            let run = line[index...].prefix { $0 == "`" }.count
            let contentStart = line.index(index, offsetBy: run)
            guard let close = closingRun(of: run, in: line, from: contentStart) else {
                prose += String(line[index..<contentStart])
                index = contentStart
                continue
            }
            out += linkedProse(prose)
            prose = ""
            let span = String(line[index..<line.index(close, offsetBy: run)])
            out += linkedSpan(span, content: String(line[contentStart..<close]))
            index = line.index(close, offsetBy: run)
        }
        return out + linkedProse(prose)
    }

    /// An existing link to a workbench path, pointed at the file; any
    /// other link (or image) as it is.
    private static func relinked(_ link: String) -> String {
        let text = link as NSString
        guard let parts = linkParts.firstMatch(in: link, range: NSRange(location: 0, length: text.length)) else { return link }
        let target = text.substring(with: parts.range(at: 2)) as NSString
        guard let match = pathTarget.firstMatch(in: target as String, range: NSRange(location: 0, length: target.length)) else {
            return link
        }
        let filePath = target.substring(with: match.range(at: 1))
        guard !filePath.split(separator: "/").contains("..") else { return link }
        let number = { (group: Int) -> Int? in
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(target.substring(with: range))
        }
        let line = max(number(2) ?? number(4) ?? 1, 1)
        return "[\(text.substring(with: parts.range(at: 1)))](\(url(path: filePath, line: line, col: number(3))))"
    }

    /// Where a backtick run of exactly `count` starts, from `start` on.
    private static func closingRun(of count: Int, in line: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < line.endIndex {
            guard line[index] == "`" else {
                index = line.index(after: index)
                continue
            }
            let run = line[index...].prefix { $0 == "`" }.count
            if run == count { return index }
            index = line.index(index, offsetBy: run)
        }
        return nil
    }

    private static func linkedSpan(_ span: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = spanCitation.firstMatch(in: trimmed, range: range),
              let link = link(for: match, in: trimmed as NSString) else { return span }
        return "[\(span)](\(link))"
    }

    private static func linkedProse(_ prose: String) -> String {
        let text = prose as NSString
        var out = ""
        var last = 0
        for match in bareCitation.matches(in: prose, range: NSRange(location: 0, length: text.length)) {
            guard let link = link(for: match, in: text) else { continue }
            out += text.substring(with: NSRange(location: last, length: match.range.location - last))
            out += "[\(text.substring(with: match.range))](\(link))"
            last = match.range.location + match.range.length
        }
        return out + text.substring(from: last)
    }

    /// Groups: 1 path, 2 line, 3 column.
    private static func link(for match: NSTextCheckingResult, in text: NSString) -> String? {
        guard let line = Int(text.substring(with: match.range(at: 2))) else { return nil }
        let colRange = match.range(at: 3)
        let col = colRange.location == NSNotFound ? nil : Int(text.substring(with: colRange))
        return url(path: text.substring(with: match.range(at: 1)), line: line, col: col)
    }
}
