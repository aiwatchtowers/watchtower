import Foundation

/// A row's one-line summary: the recipe's `summary:` key, else the first
/// sentence of its description (the body text outside the ```js block).
package enum AutomationRowSummary {
    package static let maxRunes = 60

    /// The `summary:` value, else the fallback of the body description, else nil.
    package static func summary(recipeText: String) -> String? {
        if let own = RecipeFrontmatter.summary(in: recipeText), !own.isEmpty { return own }
        let text = fallback(description: description(recipeText: recipeText))
        return text.isEmpty ? nil : text
    }

    /// The first sentence of `description` (ends at the first ". ", "! " or
    /// "? ", or the end of the text), at most `maxRunes` runes: a longer one is
    /// cut back to the last space within `maxRunes` runes and gets "…".
    /// Twin: mirrors Go `automations.FallbackSummary` line by line (runes are
    /// unicode scalars, only the ends are trimmed); change both together.
    package static func fallback(description: String) -> String {
        var scalars = Array(description.unicodeScalars)
        trim(&scalars)
        var end = scalars.count
        for sep in [". ", "! ", "? "] {
            if let i = index(of: sep, in: scalars), i + 1 < end { end = i + 1 }
        }
        scalars = Array(scalars[..<end])
        trim(&scalars)
        if scalars.count <= maxRunes { return scalarString(scalars) }
        var cut = Array(scalars[..<maxRunes])
        if let i = cut.lastIndex(of: " "), i > 0 { cut = Array(cut[..<i]) }
        while let last = cut.last, " ,;:".unicodeScalars.contains(last) { cut.removeLast() }
        return scalarString(cut) + "…"
    }

    private static func scalarString(_ scalars: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    private static func index(of sep: String, in scalars: [Unicode.Scalar]) -> Int? {
        let needle = Array(sep.unicodeScalars)
        guard scalars.count >= needle.count else { return nil }
        for i in 0...(scalars.count - needle.count) where Array(scalars[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    /// Go `strings.TrimSpace` on both ends.
    private static func trim(_ scalars: inout [Unicode.Scalar]) {
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        let lead = scalars.prefix { $0.properties.isWhitespace }.count
        scalars.removeFirst(lead)
    }

    /// The recipe body outside the frontmatter and the ```js block, as Go's
    /// `parseBody` collects it; other fenced blocks stay in.
    static func description(recipeText: String) -> String {
        let end = RecipeFrontmatter.block(in: recipeText)?.endIndex ?? recipeText.startIndex
        // UTF-16 split: "\r\n" is one Character, but Go splits on "\n" and keeps the "\r".
        let lines = String(recipeText[end...]).components(separatedBy: "\n")
        var out: [String] = []
        var closing: (char: Character, count: Int)?
        var skipping = false
        for line in lines {
            let stripped = Substring(line).drop { $0 == " " }
            let indent = line.count - stripped.count
            if let open = closing {
                let run = stripped.prefix { $0 == open.char }
                // Go `fence.closes`: only spaces and tabs may trail the fence.
                let isClose = indent <= 3 && run.count >= open.count
                    && stripped.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
                if isClose { closing = nil; if skipping { skipping = false; continue } }
                if !skipping { out.append(line) }
                continue
            }
            if indent <= 3, let char = stripped.first, char == "`" || char == "~" {
                let run = stripped.prefix { $0 == char }
                if run.count >= 3 {
                    let rest = stripped.dropFirst(run.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    let info = rest.prefix { $0 != " " && $0 != "\t" }.description
                    if !(char == "`" && rest.contains("`")) {
                        closing = (char, run.count)
                        skipping = ["js", "javascript"].contains(info.lowercased())
                        if !skipping { out.append(line) }
                        continue
                    }
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
