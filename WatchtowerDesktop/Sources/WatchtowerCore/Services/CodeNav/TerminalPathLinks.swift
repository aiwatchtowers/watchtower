import Foundation

/// `path:line(:col)` in a workbench session's terminal (spec 2026-10-02
/// §9.5): ⌘-click opens the file in Files at that line. A link is resolved
/// against the session's folder and is one only when it names an existing
/// regular file inside it; a URL, a path outside the folder, a missing file
/// or a path without a line is not one. Containment is checked lexically
/// first (ruling R53): a path outside the folder never touches the disk — a
/// `realpath` or `stat` of `~/Desktop/…` could raise a macOS privacy prompt
/// attributed to Watchtower. Only an in-folder candidate is resolved
/// (`WorkbenchFolderPath`), and a symlink leaving the folder is refused by
/// its target's text before that target is looked at.
package enum TerminalPathLinks {
    package struct Location: Equatable, Sendable {
        /// Relative to the session's folder.
        package let path: String
        package let line: Int
        package let col: Int?

        package init(path: String, line: Int, col: Int?) {
            self.path = path
            self.line = line
            self.col = col
        }
    }

    /// The disk lookups `resolve` makes, a seam for tests.
    package typealias FileSystem = WorkbenchFolderPath.FileSystem

    /// What a ⌘-clicked link does.
    package enum LinkAction: Equatable, Sendable {
        /// A file of the folder: Files at the line.
        case open(Location)
        /// A web (or mail…) URL: SwiftTerm's own handler.
        case systemHandler
        /// Anything else, a `file://` outside the folder included: nothing.
        case none
    }

    private static let quotes: Set<Character> = ["\"", "'", "`"]
    /// Around a link in prose or compiler output: `(x.go:3).`, `a.swift:12:`.
    private static let trailingPunctuation: Set<Character> = [",", ".", ";", ":", ")", "]", "}", ">", "!", "?"]
    private static let leadingBrackets: Set<Character> = ["(", "[", "{", "<"]
    private static let suffix = try? NSRegularExpression(pattern: #"^:(\d+)(?::(\d+))?$"#)
    private static let scheme = try? NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.-]*://|^(?:mailto|tel|news|magnet):"#)
    private static let fileScheme = "file://"

    /// A URL is SwiftTerm's to open, never a path link (`http://host:80`).
    /// A file name is not a scheme: `A.swift:12` is a path.
    package static func isURL(_ link: String) -> Bool {
        let range = NSRange(link.startIndex..., in: link)
        return scheme?.firstMatch(in: link, range: range) != nil
    }

    /// SwiftTerm's link at a ⌘-click: a `file://` link is a path like any
    /// other (resolved, else nothing — never opened outside the folder),
    /// another URL keeps SwiftTerm's handler.
    package static func action(
        for link: String, folder: String, folderRealPath: String?, fileSystem: FileSystem = .live
    ) -> LinkAction {
        var path = link
        if link.lowercased().hasPrefix(fileScheme) {
            let rest = String(link.dropFirst(fileScheme.count))
            path = rest.removingPercentEncoding ?? rest
        } else if isURL(link) {
            return .systemHandler
        }
        return resolve(path, folder: folder, folderRealPath: folderRealPath, fileSystem: fileSystem).map(LinkAction.open) ?? .none
    }

    /// The file and line `link` names inside `folder`, or nil.
    /// `folderRealPath` is the folder with symlinks resolved (computed once
    /// per session; nil = looked up here).
    package static func resolve(
        _ link: String, folder: String, folderRealPath: String? = nil, fileSystem: FileSystem = .live
    ) -> Location? {
        guard !isURL(link), let (path, line, col) = split(trimmed(link)), !path.isEmpty, line >= 1 else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = lexicallyNormalized(expanded.hasPrefix("/") ? expanded : folder + "/" + expanded)
        let lexicalRoot = lexicallyNormalized(folder)
        // Outside both spellings of the folder: refused before any disk call.
        let roots = [lexicalRoot, folderRealPath.map(lexicallyNormalized)].compactMap(\.self)
        guard let root = roots.first(where: { isInside(absolute, root: $0) }),
              let file = WorkbenchFolderPath.resolve(String(absolute.dropFirst(root.count + 1)), folder: folder,
                                                     folderRealPath: folderRealPath, fileSystem: fileSystem)
        else { return nil }
        return Location(path: file, line: line, col: col)
    }

    /// What was ⌘-clicked at `column` (a character offset) of a terminal
    /// line: the quoted span holding it with any `:line(:col)` right after
    /// the closing quote, else the whitespace-delimited token. nil on a
    /// space outside quotes or past the line.
    package static func candidate(inLine line: String, at column: Int) -> String? {
        candidateSpan(inLine: line, at: column)?.filter { $0 != wideSpill }
    }

    private static func candidateSpan(inLine line: String, at column: Int) -> String? {
        let chars = Array(line)
        guard column >= 0, column < chars.count else { return nil }
        if let quoted = quotedSpan(chars, around: column) { return quoted }
        guard chars[column] != " " else { return nil }
        var start = column
        while start > 0, chars[start - 1] != " " { start -= 1 }
        var end = column + 1
        while end < chars.count, chars[end] != " " { end += 1 }
        return String(chars[start..<end])
    }

    /// The cell a wide character spills into, in a `Row`: keeps one
    /// character per cell, and is dropped from a candidate.
    package static let wideSpill: Character = "\u{0}"

    /// One screen row: its cells as characters (one per cell, blanks
    /// included) and whether it continues the row above (a soft wrap).
    package struct Row: Equatable, Sendable {
        package let text: String
        package let continuesAbove: Bool

        package init(text: String, continuesAbove: Bool) {
            self.text = text
            self.continuesAbove = continuesAbove
        }
    }

    /// The logical line a ⌘-click at `row`/`column` falls in — the rows a
    /// long path wrapped over joined back — and the column within it; nil
    /// off the screen, or when the line holds right-to-left text: the
    /// terminal may draw it reordered, so a screen column names no
    /// character of it (board #361).
    package static func logicalLine(rows: [Row], row: Int, column: Int) -> (line: String, column: Int)? {
        guard rows.indices.contains(row), column >= 0 else { return nil }
        var start = row
        while start > 0, rows[start].continuesAbove { start -= 1 }
        var end = row
        while end + 1 < rows.count, rows[end + 1].continuesAbove { end += 1 }
        let line = rows[start...end].map(\.text).joined()
        guard !line.unicodeScalars.contains(where: isRightToLeft) else { return nil }
        let offset = rows[start..<row].reduce(0) { $0 + $1.text.count }
        var trimmed = line
        while trimmed.last == " " { trimmed.removeLast() }
        return (trimmed, offset + column)
    }

    // MARK: - Private

    /// Hebrew, Arabic, Syriac, Thaana, NKo and their presentation forms.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
        default: false
        }
    }

    private static func quotedSpan(_ chars: [Character], around column: Int) -> String? {
        for quote in quotes {
            let positions = chars.indices.filter { chars[$0] == quote }
            var pair = 0
            while pair + 1 < positions.count {
                let open = positions[pair], close = positions[pair + 1]
                if open <= column, column <= close {
                    var end = close + 1
                    while end < chars.count, chars[end] == ":" || chars[end].isNumber { end += 1 }
                    return String(chars[open..<end])
                }
                pair += 2
            }
        }
        return nil
    }

    /// Leading brackets and trailing punctuation dropped.
    private static func trimmed(_ link: String) -> String {
        var text = Substring(link.trimmingCharacters(in: .whitespaces))
        while let first = text.first, leadingBrackets.contains(first) { text = text.dropFirst() }
        while let last = text.last, trailingPunctuation.contains(last) {
            text = text.dropLast()
        }
        return String(text)
    }

    /// `"a b.txt":1`, `"a b.txt:1"` or `x/y.go:3:7` → path, line, column.
    private static func split(_ text: String) -> (String, Int, Int?)? {
        var body = text
        var rest = ""
        if let first = body.first, quotes.contains(first) {
            let inner = body.dropFirst()
            guard let close = inner.firstIndex(of: first) else { return nil }
            rest = String(inner[inner.index(after: close)...])
            body = String(inner[..<close])
        }
        if rest.isEmpty {
            // The suffix is inside the quotes or the token: the last one or
            // two `:digits` groups.
            guard let range = body.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) else { return nil }
            rest = String(body[range])
            body = String(body[..<range.lowerBound])
        }
        let range = NSRange(rest.startIndex..., in: rest)
        guard let match = suffix?.firstMatch(in: rest, range: range),
              let lineRange = Range(match.range(at: 1), in: rest), let line = Int(rest[lineRange]) else { return nil }
        let col = Range(match.range(at: 2), in: rest).flatMap { Int(rest[$0]) }
        return (body, line, col)
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// By the text alone (no disk access: `URL.standardized` may stat the
    /// path).
    private static func lexicallyNormalized(_ path: String) -> String {
        WorkbenchFolderPath.lexicallyNormalized(path)
    }
}
