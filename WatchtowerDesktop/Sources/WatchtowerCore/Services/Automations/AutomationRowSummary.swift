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
    /// cut on a space and gets "…".
    /// Twin: mirrors Go `automations.FallbackSummary`; change both together.
    package static func fallback(description: String) -> String {
        let text = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var sentence = Substring(text)
        for mark in [". ", "! ", "? "] {
            if let range = sentence.range(of: mark) { sentence = sentence[..<sentence.index(after: range.lowerBound)] }
        }
        let runes = Array(sentence)
        if runes.count <= maxRunes { return String(sentence) }
        var cut = Array(runes[..<maxRunes])
        if runes[maxRunes] != " ", let space = cut.lastIndex(of: " ") { cut = Array(cut[..<space]) }
        return String(cut).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The recipe body outside the frontmatter and the ```js block, as Go's
    /// `parseBody` collects it; other fenced blocks stay in.
    static func description(recipeText: String) -> String {
        let end = RecipeFrontmatter.block(in: recipeText)?.endIndex ?? recipeText.startIndex
        let lines = recipeText[end...].split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        var closing: (char: Character, count: Int)?
        var skipping = false
        for line in lines {
            let stripped = line.drop { $0 == " " }
            let indent = line.count - stripped.count
            if let open = closing {
                let run = stripped.prefix { $0 == open.char }
                let isClose = indent <= 3 && run.count >= open.count
                    && stripped.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
                if isClose { closing = nil; if skipping { skipping = false; continue } }
                if !skipping { out.append(line) }
                continue
            }
            if indent <= 3, let char = stripped.first, char == "`" || char == "~" {
                let run = stripped.prefix { $0 == char }
                if run.count >= 3 {
                    let info = stripped.dropFirst(run.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !(char == "`" && info.contains("`")) {
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
