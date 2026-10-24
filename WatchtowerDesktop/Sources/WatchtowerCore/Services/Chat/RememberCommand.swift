import Foundation

/// The Swift twin of Go `instructions.ParseRemember`
/// (`internal/instructions/remember.go`), pinned by the shared fixture
/// `internal/instructions/testdata/remember_cases.json`. The chat shows a
/// "Remembered" note for a message the CLI stored as an instruction; this
/// decides which messages are such commands.
///
/// Everything works on Unicode scalars, as Go works on runes: a Swift
/// `Character` would fuse "\r\n" and a combining mark with the scalar before.
package enum RememberCommand {
    /// Checked in order, so "remember this:" is never read as a shorter
    /// prefix. All lower case.
    private static let prefixes = ["remember this:", "remember:", "запомни:"].map { Array($0.unicodeScalars) }

    /// The rest of `text` after a remember prefix (leading space allowed,
    /// prefix case-insensitive) with every whitespace run collapsed to one
    /// space; `""` is a command with no rule. `nil` is not a command.
    package static func parse(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars.drop { isSpace($0) })
        for prefix in prefixes where scalars.count >= prefix.count {
            let head = scalars[..<prefix.count].flatMap(lower)
            if head == prefix {
                return collapse(scalars[prefix.count...])
            }
        }
        return nil
    }

    /// Go `unicode.IsSpace`: the White_Space property (U+0085 and U+00A0
    /// included).
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Go `strings.ToLower` is a per-rune simple mapping; Swift's
    /// `lowercaseMapping` is the full one, which differs only for U+0130
    /// ("İ" is "i" in Go, "i" + combining dot above in full mapping).
    private static func lower(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if scalar.value == 0x130 { return ["i"] }
        return Array(scalar.properties.lowercaseMapping.unicodeScalars)
    }

    /// Go `strings.Join(strings.Fields(rest), " ")`.
    private static func collapse(_ rest: ArraySlice<Unicode.Scalar>) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in rest {
            if isSpace(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        return String(out)
    }
}
