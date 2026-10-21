import Foundation

/// Reading a recipe's frontmatter back from its text, for the draft column
/// (its When, Each run and Missed and Concurrency boxes). Display only: the
/// fields that are hashed and confirmed are the ones `validate` reports, and
/// Go's strict parser decides what is valid. A subset of YAML — block maps
/// and lists, inline `[…]` lists and `{…}` maps one level deep, plain,
/// single- and double-quoted scalars, `#` comments — covers what `render`
/// writes and what a person or the assistant usually types. Anything else
/// (anchors, multi-line scalars, a missing or ambiguous trigger, a number
/// that is not an integer) reads as nil: the column says it can't read it
/// rather than guess.
extension RecipeFrontmatter {
    package static func read(_ recipeText: String) -> Self? {
        guard let block = block(in: recipeText) else { return nil }
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.hasSuffix("\r") ? line.dropLast() : line)
        }
        // The fences: the first line and the closing `---` line.
        lines.removeFirst()
        if let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(last...)
        }
        var reader = YAMLReader(lines: lines)
        guard let root = reader.map(indent: 0), reader.isAtEnd else { return nil }
        return fields(root)
    }

    private static func fields(_ root: [String: YAMLNode]) -> Self? {
        guard case let .map(trigger)? = root["trigger"], let parsed = parseTrigger(trigger) else { return nil }
        var f = Self(name: root["name"]?.string ?? "", trigger: parsed)
        if let missed = root["missed"] {
            guard let value = missed.string else { return nil }
            f.missed = value == "skip" ? "skip" : "run_once"
        }
        guard let concurrency = integer(root["concurrency"], default: f.concurrency),
              let hours = integer(root["pause_timeout_hours"], default: f.pauseTimeoutHours),
              let permissions = list(root["permissions"]), let outputs = list(root["outputs"]) else { return nil }
        f.concurrency = concurrency
        f.pauseTimeoutHours = hours
        f.permissions = permissions
        f.outputs = outputs
        if let budget = root["budget"] {
            guard case let .map(b) = budget,
                  let tokens = integer(b["tokens"], default: f.budgetTokens),
                  let minutes = integer(b["minutes"], default: f.budgetMinutes) else { return nil }
            f.budgetTokens = tokens
            f.budgetMinutes = minutes
        }
        return f
    }

    private static func parseTrigger(_ trigger: [String: YAMLNode]) -> Trigger? {
        guard trigger.count == 1, let (key, node) = trigger.first else { return nil }
        switch key {
        case "schedule":
            return node.string.map(Trigger.schedule)
        case "button":
            guard case let .map(b) = node, let label = b["label"]?.string else { return nil }
            return .button(label: label, confirm: b["confirm"]?.string == "true")
        case "event":
            guard case let .map(e) = node, let type = e["type"]?.string else { return nil }
            var filter: [String: String] = [:]
            if let whereNode = e["where"] {
                guard case let .map(w) = whereNode else { return nil }
                for (k, v) in w {
                    guard let value = v.string else { return nil }
                    filter[k] = value
                }
            }
            return .event(type: type, where: filter)
        case "manual":
            return node.string == "true" ? .manual : nil
        default:
            return nil
        }
    }

    private static func integer(_ node: YAMLNode?, default value: Int) -> Int? {
        guard let node else { return value }
        return node.string.flatMap { Int($0) }
    }

    private static func list(_ node: YAMLNode?) -> [String]? {
        switch node {
        case nil: return []
        case let .list(items)?: return items
        case .scalar?, .map?: return nil
        }
    }
}

private enum YAMLNode {
    case scalar(String)
    case list([String])
    case map([String: Self])

    var string: String? {
        if case let .scalar(s) = self { s } else { nil }
    }
}

/// One frontmatter block, line by line.
private struct YAMLReader {
    private struct Line {
        let indent: Int
        let text: String
    }

    private let lines: [Line]
    private var index = 0

    init(lines: [String]) {
        self.lines = lines.compactMap { raw in
            let text = Self.stripComment(raw)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let indent = text.prefix { $0 == " " }.count
            return Line(indent: indent, text: trimmed)
        }
    }

    var isAtEnd: Bool { index == lines.count }

    /// The block map whose keys sit at exactly `indent`; nil on a line this
    /// reader does not take.
    mutating func map(indent: Int) -> [String: YAMLNode]? {
        var out: [String: YAMLNode] = [:]
        while index < lines.count, lines[index].indent >= indent {
            let line = lines[index]
            guard line.indent == indent, !line.text.hasPrefix("- "),
                  let (key, rest) = Self.keyValue(line.text), out[key] == nil else { return nil }
            index += 1
            if !rest.isEmpty {
                guard let node = Self.inline(rest) else { return nil }
                out[key] = node
                continue
            }
            guard index < lines.count, lines[index].indent >= indent else {
                out[key] = .scalar("")
                continue
            }
            let next = lines[index]
            if next.text.hasPrefix("- ") || next.text == "-" {
                guard next.indent >= indent, let items = list(indent: next.indent) else { return nil }
                out[key] = .list(items)
            } else if next.indent > indent {
                guard let nested = map(indent: next.indent) else { return nil }
                out[key] = .map(nested)
            } else {
                out[key] = .scalar("")
            }
        }
        return out
    }

    /// A block list of scalars whose `- ` sits at `indent`.
    private mutating func list(indent: Int) -> [String]? {
        var items: [String] = []
        while index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("- ") {
            let item = String(lines[index].text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard let value = Self.scalar(item) else { return nil }
            items.append(value)
            index += 1
        }
        return items
    }

    /// `key: value` → (key, value); the key may be quoted.
    private static func keyValue(_ text: String) -> (String, String)? {
        guard let colon = topLevelIndex(of: ":", in: text, requireSpaceAfter: true) else { return nil }
        let rawKey = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        guard let key = scalar(rawKey), !key.isEmpty else { return nil }
        let rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    private static func inline(_ text: String) -> YAMLNode? {
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { return nil }
            let items = splitTopLevel(String(text.dropFirst().dropLast()))
            var out: [String] = []
            for item in items {
                guard let value = scalar(item) else { return nil }
                out.append(value)
            }
            return .list(out)
        }
        if text.hasPrefix("{") {
            guard text.hasSuffix("}") else { return nil }
            var out: [String: YAMLNode] = [:]
            for pair in splitTopLevel(String(text.dropFirst().dropLast())) {
                guard let colon = topLevelIndex(of: ":", in: pair, requireSpaceAfter: true),
                      let key = scalar(String(pair[..<colon]).trimmingCharacters(in: .whitespaces)),
                      let value = scalar(String(pair[pair.index(after: colon)...])
                          .trimmingCharacters(in: .whitespaces)),
                      out[key] == nil else { return nil }
                out[key] = .scalar(value)
            }
            return .map(out)
        }
        return scalar(text).map(YAMLNode.scalar)
    }

    /// A plain, single- or double-quoted scalar; nil for what this reader
    /// does not take (anchors, aliases, tags, block scalars, a bad quote).
    private static func scalar(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") { return doubleQuoted(text) }
        if text.hasPrefix("'") {
            guard text.count >= 2, text.hasSuffix("'") else { return nil }
            let body = String(text.dropFirst().dropLast())
            let unescaped = body.replacingOccurrences(of: "''", with: "\u{0}")
            guard !unescaped.contains("'") else { return nil }
            return unescaped.replacingOccurrences(of: "\u{0}", with: "'")
        }
        guard let first = text.first, !"&*!|>[{@`%".contains(first) else { return text.isEmpty ? "" : nil }
        return text
    }

    private static func doubleQuoted(_ text: String) -> String? {
        var out = ""
        var scalars = text.unicodeScalars.dropFirst().makeIterator()
        while let c = scalars.next() {
            switch c {
            case "\"":
                return scalars.next() == nil ? out : nil
            case "\\":
                guard let e = scalars.next(), let unescaped = escape(e, rest: &scalars) else { return nil }
                out.unicodeScalars.append(unescaped)
            default:
                out.unicodeScalars.append(c)
            }
        }
        return nil
    }

    /// The character a `\e` escape stands for (`\uXXXX` reads its four hex
    /// digits from `rest`); nil for an escape `render` never writes.
    private static func escape<I: IteratorProtocol>(_ e: Unicode.Scalar, rest: inout I) -> Unicode.Scalar?
        where I.Element == Unicode.Scalar {
        switch e {
        case "\\", "\"", "/": return e
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "0": return "\u{0}"
        case "u":
            var hex = ""
            for _ in 0..<4 { if let h = rest.next() { hex.unicodeScalars.append(h) } }
            guard hex.count == 4, let value = UInt32(hex, radix: 16) else { return nil }
            return Unicode.Scalar(value)
        default: return nil
        }
    }

    /// The line without a `#` comment (one at the start or after a blank,
    /// outside quotes).
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character = " "
        for (offset, c) in line.enumerated() {
            if let open = quote {
                if escaped { escaped = false } else if c == "\\", open == "\"" { escaped = true } else if c == open {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " || previous == "\t" {
                return String(line.prefix(offset))
            }
            previous = c
        }
        return line
    }

    /// The first `target` outside quotes and brackets (for `:`, followed by a
    /// blank or the end, as YAML wants).
    private static func topLevelIndex(of target: Character, in text: String, requireSpaceAfter: Bool)
        -> String.Index? {
        var quote: Character?
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let open = quote {
                if escaped { escaped = false } else if c == "\\", open == "\"" { escaped = true } else if c == open {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == target {
                let next = text.index(after: i)
                if !requireSpaceAfter || next == text.endIndex || text[next] == " " { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Comma-separated items outside quotes; blanks dropped.
    private static func splitTopLevel(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for c in text {
            if let open = quote {
                if escaped { escaped = false } else if c == "\\", open == "\"" { escaped = true } else if c == open {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "," {
                items.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
