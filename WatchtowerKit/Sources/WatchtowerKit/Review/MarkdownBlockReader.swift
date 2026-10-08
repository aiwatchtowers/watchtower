import Foundation

/// One block of a Markdown document, its inline text already rendered to
/// plain text (`MarkdownInlineText`).
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, title: String)
    case paragraph(String)
    case code(String)
    case list(MarkdownList)
    case quote([Self])
    /// The header row first; every cell rendered.
    case table([[String]])
    case rule
}

struct MarkdownList: Equatable {
    enum Task: Equatable { case none, checked, unchecked }

    struct Item: Equatable {
        let task: Task
        let blocks: [MarkdownBlock]
    }

    let ordered: Bool
    let start: Int
    let items: [Item]
}

/// The block structure of a Markdown document: a small line-based reader
/// for the CommonMark blocks (ATX and setext headings, paragraphs, fenced
/// and indented code, quotes, lists, thematic breaks, HTML blocks) and GFM
/// tables and task items. HTML blocks read as a paragraph of their raw text,
/// as Core keeps them.
struct MarkdownBlockReader {
    private let lines: [String]
    private var index = 0

    static func read(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { MarkdownLine.expandingTabs(String($0)) }
        var reader = Self(lines: lines)
        return reader.blocks()
    }

    private init(lines: [String]) {
        self.lines = lines
    }

    private mutating func blocks() -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            if MarkdownLine.isBlank(line) {
                index += 1
            } else {
                out.append(nextBlock(line))
            }
        }
        return out
    }

    /// Reads the block starting at `line` (not blank); always moves on.
    private mutating func nextBlock(_ line: String) -> MarkdownBlock {
        if let fence = MarkdownLine.Fence(line) { return code(fence) }
        if let heading = MarkdownLine.atxHeading(line) {
            index += 1
            return .heading(level: heading.level, title: MarkdownInlineText.render(heading.text))
        }
        if MarkdownLine.isThematicBreak(line) {
            index += 1
            return .rule
        }
        if MarkdownLine.quoteContent(line) != nil { return quote() }
        if let marker = MarkdownLine.ListMarker(line) { return list(marker) }
        if MarkdownLine.indent(line) >= 4 { return indentedCode() }
        if isTableStart(index) { return table() }
        if MarkdownLine.startsHTMLBlock(line) { return html() }
        return paragraph()
    }

    // MARK: - Code

    private mutating func code(_ fence: MarkdownLine.Fence) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            index += 1
            if fence.closes(line) { break }
            body.append(MarkdownLine.dropIndent(line, upTo: fence.indent))
        }
        return .code(body.joined(separator: "\n"))
    }

    private mutating func indentedCode() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count, MarkdownLine.isBlank(lines[index]) || MarkdownLine.indent(lines[index]) >= 4 {
            body.append(MarkdownLine.dropIndent(lines[index], upTo: 4))
            index += 1
        }
        while let last = body.last, MarkdownLine.isBlank(last) { body.removeLast() }
        return .code(body.joined(separator: "\n"))
    }

    // MARK: - Containers

    private mutating func quote() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if let content = MarkdownLine.quoteContent(line) {
                body.append(content)
            } else if !MarkdownLine.isBlank(line), !(body.last.map(MarkdownLine.isBlank) ?? true), !startsBlock(line) {
                // A lazy continuation of the quoted paragraph.
                body.append(line)
            } else {
                break
            }
            index += 1
        }
        return .quote(Self.read(body.joined(separator: "\n")))
    }

    private mutating func list(_ first: MarkdownLine.ListMarker) -> MarkdownBlock {
        var items: [MarkdownList.Item] = []
        var marker = first
        while true {
            items.append(item(marker))
            var next = index
            while next < lines.count, MarkdownLine.isBlank(lines[next]) { next += 1 }
            guard next < lines.count,
                  !MarkdownLine.isThematicBreak(lines[next]),
                  let following = MarkdownLine.ListMarker(lines[next]),
                  following.continues(first) else { break }
            index = next
            marker = following
        }
        return .list(MarkdownList(ordered: first.ordered, start: first.start, items: items))
    }

    private mutating func item(_ marker: MarkdownLine.ListMarker) -> MarkdownList.Item {
        var body = [marker.content]
        index += 1
        while index < lines.count {
            let line = lines[index]
            if MarkdownLine.isBlank(line) {
                body.append("")
            } else if MarkdownLine.indent(line) >= marker.contentOffset {
                body.append(MarkdownLine.dropIndent(line, upTo: marker.contentOffset))
            } else if !(body.last.map(MarkdownLine.isBlank) ?? true), !startsBlock(line), MarkdownLine.ListMarker(line) == nil {
                // A lazy continuation; any marker here is the next item.
                body.append(line)
            } else {
                break
            }
            index += 1
        }
        while body.count > 1, let last = body.last, MarkdownLine.isBlank(last) {
            body.removeLast()
            index -= 1
        }
        let (task, first) = MarkdownLine.task(body[0])
        body[0] = first
        return MarkdownList.Item(task: task, blocks: Self.read(body.joined(separator: "\n")))
    }

    // MARK: - Tables

    private func isTableStart(_ at: Int) -> Bool {
        guard at + 1 < lines.count, lines[at].contains("|") else { return false }
        guard let alignments = MarkdownLine.tableDelimiterCells(lines[at + 1]) else { return false }
        return MarkdownLine.tableCells(lines[at]).count == alignments
    }

    private mutating func table() -> MarkdownBlock {
        let header = MarkdownLine.tableCells(lines[index])
        index += 2
        var rows = [header]
        while index < lines.count, !MarkdownLine.isBlank(lines[index]), !startsBlock(lines[index]) {
            rows.append(Array(MarkdownLine.tableCells(lines[index]).prefix(header.count)))
            index += 1
        }
        return .table(rows.map { $0.map(MarkdownInlineText.render) })
    }

    // MARK: - Leaf text

    private mutating func html() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count, !MarkdownLine.isBlank(lines[index]) {
            body.append(lines[index])
            index += 1
        }
        return .paragraph(body.joined(separator: "\n") + "\n")
    }

    private mutating func paragraph() -> MarkdownBlock {
        var body = [lines[index]]
        index += 1
        while index < lines.count {
            let line = lines[index]
            if let level = MarkdownLine.setextLevel(line) {
                index += 1
                return .heading(level: level, title: MarkdownInlineText.render(Self.joined(body)))
            }
            if MarkdownLine.isBlank(line) || startsBlock(line) || isTableStart(index) { break }
            body.append(line)
            index += 1
        }
        return .paragraph(MarkdownInlineText.render(Self.joined(body)))
    }

    /// A paragraph's lines, each without its leading whitespace, the last
    /// without its trailing whitespace.
    private static func joined(_ lines: [String]) -> String {
        let text = lines.map { line in String(line.drop { $0 == " " }) }.joined(separator: "\n")
        return String(text.reversed().drop { $0 == " " }.reversed())
    }

    /// Whether `line` starts a block that interrupts a paragraph.
    private func startsBlock(_ line: String) -> Bool {
        if MarkdownLine.Fence(line) != nil || MarkdownLine.atxHeading(line) != nil { return true }
        if MarkdownLine.isThematicBreak(line) || MarkdownLine.quoteContent(line) != nil { return true }
        if MarkdownLine.startsHTMLBlock(line) { return true }
        guard let marker = MarkdownLine.ListMarker(line), !MarkdownLine.isBlank(marker.content) else { return false }
        return !marker.ordered || marker.start == 1
    }
}

/// Line-level recognizers for `MarkdownBlockReader`.
enum MarkdownLine {
    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    /// Leading spaces (tabs were expanded).
    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    static func dropIndent(_ line: String, upTo count: Int) -> String {
        String(line.dropFirst(min(count, indent(line))))
    }

    /// Leading tabs as 4-column stops; tabs inside the text stay.
    static func expandingTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { return line }
        var out = ""
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            out += first == "\t" ? String(repeating: " ", count: 4 - out.count % 4) : " "
            rest = rest.dropFirst()
        }
        return out + rest
    }

    /// ```` ``` ```` or `~~~`, up to 3 spaces in.
    struct Fence {
        let character: Character
        let count: Int
        let indent: Int

        init?(_ line: String) {
            indent = MarkdownLine.indent(line)
            guard indent < 4 else { return nil }
            let rest = line.dropFirst(indent)
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            count = rest.prefix { $0 == first }.count
            guard count >= 3 else { return nil }
            // A backtick fence's info string has no backtick.
            if first == "`", rest.dropFirst(count).contains("`") { return nil }
            character = first
        }

        func closes(_ line: String) -> Bool {
            guard MarkdownLine.indent(line) < 4 else { return false }
            let rest = line.drop { $0 == " " }
            let run = rest.prefix { $0 == character }.count
            return run >= count && MarkdownLine.isBlank(String(rest.dropFirst(run)))
        }
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard indent(line) < 4 else { return nil }
        let rest = line.drop { $0 == " " }
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence: "## Title ##".
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing == text.count {
            text = ""
        } else if closing > 0, text.dropLast(closing).last == " " {
            text = text.dropLast(closing).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indent(line) < 4 else { return false }
        let marks = line.filter { $0 != " " }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// A setext underline's heading level (`===` 1, `---` 2).
    static func setextLevel(_ line: String) -> Int? {
        guard indent(line) < 4 else { return nil }
        let mark = line.trimmingCharacters(in: .whitespaces)
        guard let first = mark.first, first == "=" || first == "-", mark.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// The line inside a quote's `>`, nil when it is not quoted.
    static func quoteContent(_ line: String) -> String? {
        guard indent(line) < 4 else { return nil }
        let rest = line.drop { $0 == " " }
        guard rest.first == ">" else { return nil }
        let content = rest.dropFirst()
        return String(content.first == " " ? content.dropFirst() : content)
    }

    static func startsHTMLBlock(_ line: String) -> Bool {
        guard indent(line) < 4 else { return false }
        let rest = line.drop { $0 == " " }
        guard rest.first == "<", let next = rest.dropFirst().first else { return false }
        return next.isLetter || next == "/" || next == "!" || next == "?"
    }

    /// `- `, `* `, `+ `, `1. ` or `1) `, up to 3 spaces in.
    struct ListMarker {
        let ordered: Bool
        /// The bullet, or the ordered delimiter.
        let mark: Character
        let start: Int
        /// The item text's column.
        let contentOffset: Int
        let content: String

        init?(_ line: String) {
            let indent = MarkdownLine.indent(line)
            guard indent < 4 else { return nil }
            let rest = line.dropFirst(indent)
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let markerLength: Int
            if let bullet = rest.first, "-*+".contains(bullet) {
                ordered = false
                mark = bullet
                start = 1
                markerLength = 1
            } else if (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first, ".)".contains(delimiter) {
                ordered = true
                mark = delimiter
                start = Int(digits) ?? 1
                markerLength = digits.count + 1
            } else {
                return nil
            }
            let after = rest.dropFirst(markerLength)
            guard after.isEmpty || after.first == " " else { return nil }
            let spaces = after.prefix { $0 == " " }.count
            // Five or more spaces: the item text is indented code; read as one.
            let gap = spaces == 0 || spaces > 4 ? 1 : spaces
            contentOffset = indent + markerLength + gap
            content = String(after.dropFirst(min(gap, spaces)))
        }

        /// The next item of the same list.
        func continues(_ first: Self) -> Bool {
            ordered == first.ordered && mark == first.mark
        }
    }

    /// A GFM task item's box, and the text after it.
    static func task(_ text: String) -> (MarkdownList.Task, String) {
        for (box, task) in [("[ ] ", MarkdownList.Task.unchecked), ("[x] ", .checked), ("[X] ", .checked)] where text.hasPrefix(box) {
            return (task, String(text.dropFirst(box.count)))
        }
        return (.none, text)
    }

    /// A table row's cells, trimmed; an escaped `\|` is a pipe inside a cell.
    static func tableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in row {
            if character == "|", !escaped {
                cells.append(cell)
                cell = ""
            } else if character == "|" {
                cell.removeLast()
                cell.append(character)
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The column count of a delimiter row (`|---|:-:|`), nil for any other
    /// line.
    static func tableDelimiterCells(_ line: String) -> Int? {
        guard indent(line) < 4, line.contains("-") else { return nil }
        let cells = tableCells(line)
        let valid = cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
        return valid ? cells.count : nil
    }
}
