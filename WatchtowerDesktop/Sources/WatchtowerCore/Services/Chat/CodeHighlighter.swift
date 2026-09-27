import Foundation

package struct CodeToken: Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case plain, keyword, string, comment, number }

    package let kind: Kind
    package let text: String

    package init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A deliberately small highlighter (spec §3.3): keywords, strings, comments
/// and numbers for common languages. Lossless — the tokens always
/// concatenate back to the input — and an unknown language is one plain
/// token rather than a guess.
///
/// Memoized like `MarkdownDocument.parse` and for the same reason: a
/// streamed, growing code fence would otherwise be fully re-scanned on every
/// re-render (each delta while streaming, and again on every scroll-driven
/// row rebuild once finished).
package enum CodeHighlighter {
    private struct Spec {
        let keywords: Set<String>
        let lineComments: [String]
        let blockComments: Bool
        let quotes: Set<Character>
        let caseInsensitive: Bool
    }

    private final class Box {
        let tokens: [CodeToken]
        init(_ tokens: [CodeToken]) { self.tokens = tokens }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    package static func tokens(_ code: String, language: String?) -> [CodeToken] {
        guard !code.isEmpty else { return [] }
        guard let spec = language.flatMap({ specs[$0.lowercased()] }) else { return [CodeToken(kind: .plain, text: code)] }
        let key = cacheKey(code, language: language)
        if let hit = cache.object(forKey: key) { return hit.tokens }
        var scanner = Scanner(chars: Array(code), spec: spec)
        let tokens = scanner.run()
        cache.setObject(Box(tokens), forKey: key, cost: code.utf16.count)
        return tokens
    }

    /// Test-only: whether `code`/`language` already has a cached result,
    /// without triggering a scan — lets a test prove a repeat call is served
    /// from cache instead of re-scanning.
    package static func isCached(_ code: String, language: String?) -> Bool {
        cache.object(forKey: cacheKey(code, language: language)) != nil
    }

    // NUL-separated: language names are short identifiers, so this never
    // collides with a code sample that happens to share a prefix.
    private static func cacheKey(_ code: String, language: String?) -> NSString {
        ((language ?? "").lowercased() + "\u{0}" + code) as NSString
    }

    private struct Scanner {
        let chars: [Character]
        let spec: Spec
        var index = 0
        var out: [CodeToken] = []

        mutating func run() -> [CodeToken] {
            while index < chars.count {
                if let end = commentEnd() {
                    emit(.comment, until: end)
                } else if spec.quotes.contains(chars[index]) {
                    emit(.string, until: stringEnd())
                } else if chars[index].isNumber, !previousIsIdentifier() {
                    emit(.number, until: runEnd { $0.isHexDigit || $0 == "." || $0 == "_" || $0 == "x" })
                } else if chars[index].isLetter || chars[index] == "_" {
                    let end = runEnd { $0.isLetter || $0.isNumber || $0 == "_" }
                    let word = String(chars[index..<end])
                    let key = spec.caseInsensitive ? word.lowercased() : word
                    emit(spec.keywords.contains(key) ? .keyword : .plain, until: end)
                } else {
                    emit(.plain, until: index + 1)
                }
            }
            return out
        }

        private func startsWith(_ marker: String, at position: Int) -> Bool {
            let m = Array(marker)
            guard position + m.count <= chars.count else { return false }
            return Array(chars[position..<position + m.count]) == m
        }

        private func commentEnd() -> Int? {
            for marker in spec.lineComments where startsWith(marker, at: index) {
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                return end
            }
            guard spec.blockComments, startsWith("/*", at: index) else { return nil }
            var end = index + 2
            while end < chars.count, !startsWith("*/", at: end) { end += 1 }
            return min(end + 2, chars.count)
        }

        private func stringEnd() -> Int {
            let quote = chars[index]
            var end = index + 1
            while end < chars.count {
                if chars[end] == "\\" { end += 2; continue }
                if chars[end] == quote { return end + 1 }
                if chars[end] == "\n", quote != "`" { return end }
                end += 1
            }
            return chars.count
        }

        private func runEnd(_ predicate: (Character) -> Bool) -> Int {
            var end = index + 1
            while end < chars.count, predicate(chars[end]) { end += 1 }
            return end
        }

        private func previousIsIdentifier() -> Bool {
            guard index > 0 else { return false }
            let prev = chars[index - 1]
            return prev.isLetter || prev.isNumber || prev == "_"
        }

        private mutating func emit(_ kind: CodeToken.Kind, until end: Int) {
            let bounded = min(max(end, index + 1), chars.count)
            let text = String(chars[index..<bounded])
            if kind == .plain, let last = out.last, last.kind == .plain {
                out[out.count - 1] = CodeToken(kind: .plain, text: last.text + text)
            } else {
                out.append(CodeToken(kind: kind, text: text))
            }
            index = bounded
        }
    }

    private static let cLike: Set<Character> = ["\"", "'"]

    private static let specs: [String: Spec] = {
        let swift = Spec(keywords: ["let", "var", "func", "if", "else", "guard", "return", "struct", "class", "enum",
                                    "protocol", "extension", "import", "for", "in", "while", "switch", "case", "default",
                                    "true", "false", "nil", "self", "try", "await", "async", "throws", "private",
                                    "public", "static", "init"],
                         lineComments: ["//"], blockComments: true, quotes: ["\""], caseInsensitive: false)
        let go = Spec(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else",
                                 "for", "range", "return", "go", "defer", "switch", "case", "default", "map", "chan",
                                 "nil", "true", "false", "err"],
                      lineComments: ["//"], blockComments: true, quotes: ["\"", "'", "`"], caseInsensitive: false)
        let python = Spec(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import",
                                     "from", "as", "with", "try", "except", "finally", "raise", "lambda", "None",
                                     "True", "False", "and", "or", "not", "yield", "async", "await"],
                          lineComments: ["#"], blockComments: false, quotes: cLike, caseInsensitive: false)
        let js = Spec(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class",
                                 "import", "from", "export", "new", "this", "null", "undefined", "true", "false",
                                 "async", "await", "type", "interface"],
                      lineComments: ["//"], blockComments: true, quotes: ["\"", "'", "`"], caseInsensitive: false)
        let json = Spec(keywords: ["true", "false", "null"], lineComments: [], blockComments: false,
                        quotes: ["\""], caseInsensitive: false)
        let sql = Spec(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update",
                                  "set", "delete", "create", "table", "index", "join", "left", "on", "group", "by",
                                  "order", "limit", "as", "null", "is", "in"],
                       lineComments: ["--"], blockComments: true, quotes: cLike, caseInsensitive: true)
        let bash = Spec(keywords: ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function",
                                   "return", "export", "local", "echo"],
                        lineComments: ["#"], blockComments: false, quotes: cLike, caseInsensitive: false)
        let yaml = Spec(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComments: false,
                        quotes: cLike, caseInsensitive: true)
        let rust = Spec(keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "if",
                                   "else", "match", "for", "in", "loop", "while", "return", "true", "false", "self"],
                        lineComments: ["//"], blockComments: true, quotes: ["\""], caseInsensitive: false)
        let java = Spec(keywords: ["class", "public", "private", "protected", "static", "final", "void", "return", "if",
                                   "else", "for", "while", "new", "null", "true", "false", "import", "package", "fun",
                                   "val", "var", "when", "interface"],
                        lineComments: ["//"], blockComments: true, quotes: cLike, caseInsensitive: false)
        let c = Spec(keywords: ["int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef",
                                "const", "static", "include", "define", "class", "namespace", "auto", "nullptr"],
                     lineComments: ["//"], blockComments: true, quotes: cLike, caseInsensitive: false)
        return ["swift": swift, "go": go, "golang": go, "python": python, "py": python,
                "javascript": js, "js": js, "typescript": js, "ts": js, "jsx": js, "tsx": js,
                "json": json, "sql": sql, "bash": bash, "sh": bash, "shell": bash, "zsh": bash,
                "yaml": yaml, "yml": yaml, "rust": rust, "rs": rust,
                "java": java, "kotlin": java, "kt": java, "c": c, "cpp": c, "c++": c, "h": c]
    }()
}
