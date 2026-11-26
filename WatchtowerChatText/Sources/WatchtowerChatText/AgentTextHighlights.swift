import Foundation

/// The stretches of an agent's text the Workchat colours as an IDE colours code (spec 2026-11-24-workchat-polish §2,
/// D3): a target ref `#N`, a commit hash, a file path and a command, which the app colours and opens; and a date or
/// time and a `PR #N` / `ask #N` reference, which it only colours (spec 2026-11-26-chat-text-highlights). Pure. A
/// `path` is a candidate only: the app keeps it when it resolves in a session folder.
public enum AgentTextHighlights {
    public enum Kind: Sendable, Equatable {
        /// `#N`, a target number.
        case ref(Int)
        case hash
        case path
        case command
        /// A date `YYYY-MM-DD` or a time `HH:MM`.
        case time
        /// `PR #N`, the whole phrase.
        case pullRequest(Int)
        /// `ask #N`, the whole phrase.
        case ask(Int)
    }

    public struct Span: Equatable, Sendable {
        public let range: Range<String.Index>
        public let kind: Kind
        public let text: String

        public init(range: Range<String.Index>, kind: Kind, text: String) {
            self.range = range
            self.kind = kind
            self.text = text
        }
    }

    /// The first words of inline code that read as a command.
    public static let commandWords: Set<String> = ["make", "go", "swift", "git", "gh", "xcodebuild", "npm"]
    /// The project's own scripts read as commands too.
    public static let scriptPrefix = "./scripts/"
    /// A file name with one of these is a path even without a `/`.
    public static let sourceExtensions: Set<String> = ["swift", "go", "md", "sql", "yml", "json", "ts", "py", "sh"]

    /// The refs, hashes, dates and times, `PR #N` / `ask #N` phrases and path candidates in a plain-text stretch (never
    /// a code block, a link or inline code), in order of their start. A ref, hash or date may sit inside a path
    /// candidate (`#2201/T2`): the app keeps the path when it resolves and the spans inside it otherwise. The spans
    /// other than paths never overlap one another.
    public static func spans(inPlain text: String) -> [Span] {
        var steps = 0
        return spans(inPlain: text, steps: &steps)
    }

    /// `spans(inPlain:)` counting its web-address work in `steps` (tests pin that it stays linear).
    static func spans(inPlain text: String, steps: inout Int) -> [Span] {
        guard !text.isEmpty else { return [] }
        let urls = webAddresses(in: text, steps: &steps)
        let prefixed = matches(prefixedRefPattern, in: text).compactMap {
            prefixedRefSpan($0, in: text, urls: urls, steps: &steps)
        }
        // A `#N` inside `PR #N` / `ask #N` is that phrase's: one ordered pass (both lists are in text order).
        var next = 0
        let refs = matches(refPattern, in: text).compactMap { refSpan($0, in: text, urls: urls, steps: &steps) }
            .filter { ref in
                while next < prefixed.count, prefixed[next].range.upperBound <= ref.range.lowerBound { next += 1 }
                return next == prefixed.count || !prefixed[next].range.overlaps(ref.range)
            }
        let spans = matches(pathToken, in: text).compactMap { pathSpan($0, in: text, urls: urls, steps: &steps) }
            + prefixed + refs
            + matches(hashPattern, in: text).compactMap { hashSpan($0, in: text, urls: urls, steps: &steps) }
            + (matches(datePattern, in: text) + matches(clockPattern, in: text)).compactMap {
                timeSpan($0, in: text, urls: urls, steps: &steps)
            }
        return spans.sorted {
            $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.kind != .path
        }
    }

    /// Inline code as a whole (spec 2026-11-26-chat-text-highlights §1): a command (its first word in
    /// `commandWords`, or a `./scripts/…` path) without its surrounding space; otherwise the code without its
    /// surrounding space and one pair of surrounding `"` or `'`, when that whole token is one span of
    /// `spans(inPlain:)` — a ref, a hash, a `PR #N` / `ask #N` phrase, a date or time, or a path candidate. Nil for
    /// any other code (`marking_started: "2026-11-16"`, `domain-kpi-v2`).
    public static func codeSpan(inCode code: String) -> Span? {
        guard let first = code.firstIndex(where: { !$0.isWhitespace }),
              let last = code.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        var range = first..<code.index(after: last)
        let trimmed = code[range]
        let word = trimmed.prefix { !$0.isWhitespace }
        if commandWords.contains(String(word)) || (word.hasPrefix(scriptPrefix) && word.count > scriptPrefix.count) {
            return Span(range: range, kind: .command, text: String(trimmed))
        }
        if trimmed.count >= 2, let quote = trimmed.first, quote == "\"" || quote == "'", trimmed.last == quote {
            range = code.index(after: range.lowerBound)..<code.index(before: range.upperBound)
        }
        let token = String(code[range])
        // Two kinds never both cover a whole token (a path has a letter and a `/` or an extension and no `#`; a
        // hash, a ref, a phrase and a date have none of those together), so the first whole span is the one.
        guard let whole = spans(inPlain: token).first(where: { $0.range == token.startIndex..<token.endIndex })
        else { return nil }
        return Span(range: range, kind: whole.kind, text: token)
    }

    // MARK: - Patterns

    /// `PR #N` / `ask #N` (any case), standing alone, the word and the ref on one line.
    private static let prefixedRefPattern = regex(#"(?i)(?<![\w])(PR|ask)[ \t]+#(\d{1,6})(?![\w])"#)
    /// `#` and 1–6 digits at a word boundary, not inside a URL or a word (`issue#12`).
    private static let refPattern = regex(#"(?<![\w/#&])#(\d{1,6})(?![\w])"#)
    /// 7–40 lowercase hex characters standing alone (not part of a word, a path or a dotted version).
    private static let hashPattern = regex(#"(?<![\w./:-])[0-9a-f]{7,40}(?![\w/-])"#)
    /// `YYYY-MM-DD` not glued to a word, a version, a time or a ref's `#` (`#2026-11-16` is the ref); a path's `/`
    /// before it and a file's extension after it leave it a date inside that path candidate (`logs/2026-11-16.txt`).
    /// Month and day are checked in `timeSpan`.
    private static let datePattern = regex(#"(?<![\w.:#-])\d{4}-(\d{2})-(\d{2})(?![\w:/-]|\.\d)"#)
    /// `HH:MM`, 00:00–23:59, not glued to a word, a ratio, a ref's `#` (`#12:30` is the ref), seconds (`10:05:33`) or
    /// a dotted number (`10:05.1`); a sentence's full stop after it leaves it a time (`at 10:05.`).
    private static let clockPattern = regex(#"(?<![\w.:/#-])([01]\d|2[0-3]):[0-5]\d(?![\w:/-]|\.\d)"#)
    /// A run of path characters not glued to a scheme's `:` or another path character.
    private static let pathToken = regex(#"(?<![\w.+@~/:-])[\w.+@~/-]+"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals: a failure is a programming error caught by the tests.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func refSpan(
        _ match: NSTextCheckingResult, in text: String, urls: [Range<String.Index>], steps: inout Int
    ) -> Span? {
        guard let range = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text),
              let number = Int(text[digits]), !inside(range, urls, steps: &steps) else { return nil }
        return Span(range: range, kind: .ref(number), text: String(text[range]))
    }

    private static func prefixedRefSpan(
        _ match: NSTextCheckingResult, in text: String, urls: [Range<String.Index>], steps: inout Int
    ) -> Span? {
        guard let range = Range(match.range, in: text), let word = Range(match.range(at: 1), in: text),
              let digits = Range(match.range(at: 2), in: text), let number = Int(text[digits]),
              !inside(range, urls, steps: &steps) else { return nil }
        let kind: Kind = text[word].lowercased() == "pr" ? .pullRequest(number) : .ask(number)
        return Span(range: range, kind: kind, text: String(text[range]))
    }

    /// A date (its month 01–12 and day 01–31 in groups 1 and 2) or a time (one group).
    private static func timeSpan(
        _ match: NSTextCheckingResult, in text: String, urls: [Range<String.Index>], steps: inout Int
    ) -> Span? {
        guard let range = Range(match.range, in: text) else { return nil }
        if match.numberOfRanges == 3 {
            guard let month = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                  let day = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
        }
        guard !inside(range, urls, steps: &steps) else { return nil }
        return Span(range: range, kind: .time, text: String(text[range]))
    }

    private static func hashSpan(
        _ match: NSTextCheckingResult, in text: String, urls: [Range<String.Index>], steps: inout Int
    ) -> Span? {
        guard let range = Range(match.range, in: text) else { return nil }
        let token = text[range]
        guard token.contains(where: \.isNumber), token.contains(where: \.isLetter), !inside(range, urls, steps: &steps)
        else { return nil }
        return Span(range: range, kind: .hash, text: String(token))
    }

    private static func pathSpan(
        _ match: NSTextCheckingResult, in text: String, urls: [Range<String.Index>], steps: inout Int
    ) -> Span? {
        guard let whole = Range(match.range, in: text) else { return nil }
        // A sentence's full stop is not the path's.
        var end = whole.upperBound
        while end > whole.lowerBound, text[text.index(before: end)] == "." { end = text.index(before: end) }
        let range = whole.lowerBound..<end
        let token = text[range]
        guard token.contains(where: \.isLetter), !token.hasPrefix("//"),
              token.contains("/") || hasSourceExtension(token), !inside(range, urls, steps: &steps) else { return nil }
        return Span(range: range, kind: .path, text: String(token))
    }

    private static func hasSourceExtension(_ token: Substring) -> Bool {
        guard let dot = token.lastIndex(of: "."), dot > token.startIndex else { return false }
        return sourceExtensions.contains(String(token[token.index(after: dot)...]))
    }

    /// The whitespace-delimited words that are web addresses (hold `://` or start with `www.`), in order: one pass.
    private static func webAddresses(in text: String, steps: inout Int) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var isAddress = false
        var colonSlashes = 0
        var index = text.startIndex
        func close(at end: String.Index) {
            if let wordStart = start, isAddress || text[wordStart..<end].hasPrefix("www.") { out.append(wordStart..<end) }
            start = nil
            isAddress = false
            colonSlashes = 0
        }
        while index < text.endIndex {
            steps += 1
            let char = text[index]
            if char.isWhitespace {
                close(at: index)
            } else {
                if start == nil { start = index }
                // `://`: a colon, then two slashes.
                colonSlashes = char == ":" ? 1 : (char == "/" && colonSlashes > 0 ? colonSlashes + 1 : 0)
                if colonSlashes == 3 { isAddress = true }
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return out
    }

    /// Whether `range` overlaps one of the sorted web addresses (binary search).
    private static func inside(_ range: Range<String.Index>, _ urls: [Range<String.Index>], steps: inout Int) -> Bool {
        var low = 0
        var high = urls.count
        while low < high {
            steps += 1
            let mid = (low + high) / 2
            if urls[mid].upperBound <= range.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < urls.count && urls[low].lowerBound < range.upperBound
    }
}

extension AgentTextHighlights.Kind {
    /// Whether a click on a span of this kind does something (shows a target, copies, opens a file); a date, a time
    /// and a `PR #N` / `ask #N` reference are colour only (spec 2026-11-26-chat-text-highlights D1).
    public var opens: Bool {
        switch self {
        case .ref, .hash, .path, .command: true
        case .time, .pullRequest, .ask: false
        }
    }
}
