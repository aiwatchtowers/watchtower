import Foundation

/// A Markdown block's inline content as plain text, as Core renders
/// swift-markdown's inline nodes: emphasis, strong and strikethrough leave
/// their text, a code span its code, a link or image its text, a soft break
/// a space and a hard break (two trailing spaces or a backslash) a newline;
/// escapes and entities are decoded, raw inline HTML stays as written.
/// Emphasis follows CommonMark's delimiter-run rules (flanking, the rule of
/// three); `~`/`~~` strikethrough needs equal runs, as GFM's.
enum MarkdownInlineText {
    static func render(_ source: String) -> String {
        var scanner = InlineScanner(Array(source))
        let nodes = scanner.scan()
        InlineEmphasis.resolve(nodes)
        return nodes.map(\.text).joined()
    }
}

/// One piece of a scanned inline run: text to keep, or a delimiter run
/// that emphasis may consume.
private final class InlineNode {
    let literal: String
    let delimiter: Character?
    /// Delimiters not yet taken by emphasis.
    var remaining: Int
    let original: Int
    var canOpen: Bool
    var canClose: Bool

    init(_ literal: String) {
        self.literal = literal
        delimiter = nil
        remaining = 0
        original = 0
        canOpen = false
        canClose = false
    }

    init(delimiter: Character, count: Int, canOpen: Bool, canClose: Bool) {
        literal = ""
        self.delimiter = delimiter
        remaining = count
        original = count
        self.canOpen = canOpen
        self.canClose = canClose
    }

    /// What is left of it once emphasis took its delimiters.
    var text: String {
        delimiter.map { String(repeating: $0, count: remaining) } ?? literal
    }
}

private struct InlineScanner {
    private let chars: [Character]
    private var index = 0
    private var nodes: [InlineNode] = []
    private var pending = ""

    init(_ chars: [Character]) {
        self.chars = chars
    }

    mutating func scan() -> [InlineNode] {
        while index < chars.count {
            scanOne(chars[index])
        }
        flush()
        return nodes
    }

    private mutating func scanOne(_ character: Character) {
        switch character {
        case "\\": escape()
        case "`": codeSpan()
        case "&": entity()
        case "<": autolink()
        case "!" where index + 1 < chars.count && chars[index + 1] == "[":
            if !link(at: index + 1) { take(1) }
        case "[":
            if !link(at: index) { take(1) }
        case "*", "_", "~": delimiterRun(character)
        case "\n": lineBreak()
        default: take(1)
        }
    }

    private mutating func take(_ count: Int) {
        pending += String(chars[index..<min(index + count, chars.count)])
        index += count
    }

    private mutating func flush() {
        guard !pending.isEmpty else { return }
        nodes.append(InlineNode(pending))
        pending = ""
    }

    private mutating func escape() {
        guard index + 1 < chars.count else { return take(1) }
        let next = chars[index + 1]
        if next == "\n" {
            pending += "\n"
            index += 2
        } else if next.isASCII, next.isPunctuation || next.isSymbol {
            pending.append(next)
            index += 2
        } else {
            take(1)
        }
    }

    private mutating func codeSpan() {
        let run = run(of: "`", from: index)
        var search = index + run
        while search < chars.count {
            if chars[search] == "`" {
                let closing = self.run(of: "`", from: search)
                if closing == run {
                    pending += Self.codeText(chars[(index + run)..<search])
                    index = search + closing
                    return
                }
                search += closing
            } else {
                search += 1
            }
        }
        take(run)
    }

    /// A code span's content: newlines read as spaces, and one space each
    /// side stripped when both are there and it is not all spaces.
    private static func codeText(_ content: ArraySlice<Character>) -> String {
        var text = String(content).replacingOccurrences(of: "\n", with: " ")
        if text.count >= 2, text.hasPrefix(" "), text.hasSuffix(" "), text.contains(where: { $0 != " " }) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private mutating func entity() {
        guard let end = chars[index...].prefix(34).firstIndex(of: ";"),
              let decoded = InlineEntity.decode(String(chars[(index + 1)..<end])) else { return take(1) }
        pending += decoded
        index = end + 1
    }

    /// `<scheme:…>` and `<user@example.com>` read as their address; any
    /// other `<` is text (raw HTML stays as written).
    private mutating func autolink() {
        guard let end = chars[index...].firstIndex(of: ">") else { return take(1) }
        let body = String(chars[(index + 1)..<end])
        guard !body.contains(where: { $0 == " " || $0 == "<" || $0 == "\n" }), Self.isAutolink(body) else { return take(1) }
        pending += body
        index = end + 1
    }

    private static func isAutolink(_ body: String) -> Bool {
        if let colon = body.firstIndex(of: ":") {
            let scheme = body[..<colon]
            return (2...32).contains(scheme.count) && scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
        }
        return body.contains("@") && !body.hasPrefix("@") && !body.hasSuffix("@")
    }

    /// `[text](destination "title")` at `open` (the `[`): renders as its
    /// text. False when it is not an inline link.
    private mutating func link(at open: Int) -> Bool {
        guard let close = matchingBracket(from: open),
              close + 1 < chars.count, chars[close + 1] == "(",
              let end = InlineLinkTail.end(chars, from: close + 2) else { return false }
        pending += MarkdownInlineText.render(String(chars[(open + 1)..<close]))
        index = end + 1
        return true
    }

    private func matchingBracket(from open: Int) -> Int? {
        var depth = 0
        var position = open
        while position < chars.count {
            switch chars[position] {
            case "\\": position += 1
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return position }
            default: break
            }
            position += 1
        }
        return nil
    }

    private mutating func delimiterRun(_ character: Character) {
        let count = run(of: character, from: index)
        let before = index > 0 ? chars[index - 1] : " "
        let after = index + count < chars.count ? chars[index + count] : " "
        let left = !after.isWhitespace && (!Self.isPunctuation(after) || before.isWhitespace || Self.isPunctuation(before))
        let right = !before.isWhitespace && (!Self.isPunctuation(before) || after.isWhitespace || Self.isPunctuation(after))
        var canOpen = left
        var canClose = right
        if character == "_" {
            canOpen = left && (!right || Self.isPunctuation(before))
            canClose = right && (!left || Self.isPunctuation(after))
        } else if character == "~", count > 2 {
            canOpen = false
            canClose = false
        }
        flush()
        nodes.append(InlineNode(delimiter: character, count: count, canOpen: canOpen, canClose: canClose))
        index += count
    }

    /// A soft break reads as a space; two or more trailing spaces make it a
    /// hard break (a newline). Spaces before either are dropped.
    private mutating func lineBreak() {
        let spaces = pending.reversed().prefix { $0 == " " }.count
        pending.removeLast(spaces)
        pending += spaces >= 2 ? "\n" : " "
        index += 1
    }

    private func run(of character: Character, from start: Int) -> Int {
        chars[start...].prefix { $0 == character }.count
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character.isSymbol
    }
}

/// The destination and optional title after a link's `](`.
private enum InlineLinkTail {
    /// The index of the closing `)`, nil when the tail is not a valid one.
    static func end(_ chars: [Character], from start: Int) -> Int? {
        var position = skipSpaces(chars, from: start)
        guard position < chars.count else { return nil }
        if chars[position] == "<" {
            guard let close = chars[position...].firstIndex(of: ">") else { return nil }
            position = close + 1
        } else {
            position = destinationEnd(chars, from: position)
        }
        position = skipSpaces(chars, from: position)
        if position < chars.count, let closer = titleCloser(chars[position]) {
            guard let close = chars[(position + 1)...].firstIndex(of: closer) else { return nil }
            position = skipSpaces(chars, from: close + 1)
        }
        return position < chars.count && chars[position] == ")" ? position : nil
    }

    private static func destinationEnd(_ chars: [Character], from start: Int) -> Int {
        var depth = 0
        var position = start
        while position < chars.count {
            let character = chars[position]
            if character == "\\" {
                position += 2
                continue
            }
            if character.isWhitespace || (character == ")" && depth == 0) { break }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            position += 1
        }
        return min(position, chars.count)
    }

    private static func titleCloser(_ character: Character) -> Character? {
        switch character {
        case "\"": "\""
        case "'": "'"
        case "(": ")"
        default: nil
        }
    }

    private static func skipSpaces(_ chars: [Character], from start: Int) -> Int {
        var position = start
        while position < chars.count, chars[position] == " " || chars[position] == "\n" { position += 1 }
        return position
    }
}

/// CommonMark's emphasis pass over the delimiter runs: each closer takes
/// the nearest opener of its kind, two delimiters when both have two
/// (strong), else one; the runs between them can no longer pair.
private enum InlineEmphasis {
    static func resolve(_ nodes: [InlineNode]) {
        var closerIndex = 0
        while closerIndex < nodes.count {
            let closer = nodes[closerIndex]
            guard closer.delimiter != nil, closer.canClose, closer.remaining > 0 else {
                closerIndex += 1
                continue
            }
            guard let openerIndex = opener(for: closer, before: closerIndex, in: nodes) else {
                if !closer.canOpen { closer.canClose = false }
                closerIndex += 1
                continue
            }
            let opener = nodes[openerIndex]
            let used = closer.delimiter == "~" ? closer.remaining : (opener.remaining >= 2 && closer.remaining >= 2 ? 2 : 1)
            opener.remaining -= used
            closer.remaining -= used
            for between in nodes[(openerIndex + 1)..<closerIndex] {
                between.canOpen = false
                between.canClose = false
            }
            if closer.remaining <= 0 { closerIndex += 1 }
        }
    }

    private static func opener(for closer: InlineNode, before end: Int, in nodes: [InlineNode]) -> Int? {
        nodes[..<end].lastIndex { candidate in
            guard candidate.delimiter == closer.delimiter, candidate.canOpen, candidate.remaining > 0 else { return false }
            if closer.delimiter == "~" { return candidate.remaining == closer.remaining }
            // The rule of three.
            if candidate.canClose || closer.canOpen {
                let sum = candidate.original + closer.original
                return !sum.isMultiple(of: 3) || (candidate.original.isMultiple(of: 3) && closer.original.isMultiple(of: 3))
            }
            return true
        }
    }
}

/// HTML character references (`&amp;`, `&#65;`, `&#x41;`): the common named
/// ones and every numeric one.
private enum InlineEntity {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "middot": "·", "bull": "•", "times": "×", "divide": "÷", "deg": "°", "euro": "€",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓"
    ]

    static func decode(_ name: String) -> String? {
        if let value = named[name] { return value }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let hex = digits.first == "x" || digits.first == "X"
        guard let code = UInt32(hex ? String(digits.dropFirst()) : String(digits), radix: hex ? 16 : 10),
              !digits.isEmpty else { return nil }
        // An invalid or NUL code point reads as U+FFFD, as CommonMark's.
        return String(Character(Unicode.Scalar(code == 0 ? 0xFFFD : code) ?? "\u{FFFD}"))
    }
}
