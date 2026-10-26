import Foundation

/// The Swift twin of Go `ideas.ParseKnowledgePrefix`
/// (`internal/ideas/chatprefix.go`), pinned by the shared fixture
/// `internal/ideas/testdata/knowledge_prefix_cases.json`. An owner's chat
/// message behind `решили:` / `decided:` is saved as a decision, behind
/// `факт:` / `fact:` as a fact (registry kind `note`).
///
/// Works on Unicode scalars, as Go works on runes, with the same rules as
/// `RememberCommand`: a Swift `Character` would fuse a combining mark with
/// the colon before it.
package enum KnowledgePrefix {
    /// Prefix (lower case) → registry kind, checked in Go's order.
    private static let prefixes: [(prefix: [Unicode.Scalar], kind: String)] = [
        ("решили:", "decision"), ("decided:", "decision"), ("факт:", "note"), ("fact:", "note")
    ].map { (Array($0.0.unicodeScalars), $0.1) }

    /// The kind and the rest of `text` after a knowledge prefix (leading
    /// space allowed, prefix case-insensitive), trimmed with its newlines
    /// kept. An empty body is still a match; the caller reports it as empty.
    /// `nil` is not a knowledge message.
    package static func parse(_ text: String) -> (kind: String, body: String)? {
        let scalars = Array(text.unicodeScalars.drop { isSpace($0) })
        for entry in prefixes where scalars.count >= entry.prefix.count {
            if scalars[..<entry.prefix.count].flatMap(lower) == entry.prefix {
                return (entry.kind, trim(scalars[entry.prefix.count...]))
            }
        }
        return nil
    }

    /// Go `unicode.IsSpace`: the White_Space property (U+0085 and U+00A0 included).
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Go `strings.ToLower`'s per-rune simple mapping; Swift's full mapping
    /// differs only for U+0130 ("İ" is "i" in Go).
    private static func lower(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if scalar.value == 0x130 { return ["i"] }
        return Array(scalar.properties.lowercaseMapping.unicodeScalars)
    }

    /// Go `strings.TrimFunc(rest, unicode.IsSpace)`.
    private static func trim(_ rest: ArraySlice<Unicode.Scalar>) -> String {
        guard let first = rest.firstIndex(where: { !isSpace($0) }),
              let last = rest.lastIndex(where: { !isSpace($0) }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: rest[first...last])
        return String(out)
    }
}
