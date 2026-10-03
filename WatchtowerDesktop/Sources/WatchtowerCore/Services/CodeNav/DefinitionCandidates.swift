import Foundation

/// One entry of the go-to-definition menu: an index symbol (with its kind
/// badge) or a text-search line (no badge).
package struct DefinitionChoice: Equatable, Sendable {
    /// `Type.name` for a symbol, the trimmed line for a text match.
    package let title: String
    /// `path:line`
    package let location: String
    package let kind: CodeSymbolKind?
    package let target: CodeNavLocation

    package init(_ symbol: CodeSymbol) {
        title = symbol.container.isEmpty ? symbol.name : "\(symbol.container).\(symbol.name)"
        location = "\(symbol.path):\(symbol.line)"
        kind = symbol.kind
        target = CodeNavLocation(path: symbol.path, line: symbol.line, col: symbol.col)
    }

    package init(_ match: CodeSearchMatch) {
        title = String(match.text.trimmingCharacters(in: .whitespaces).prefix(DefinitionHeuristic.titleLimit))
        location = "\(match.path):\(match.line)"
        kind = nil
        target = CodeNavLocation(path: match.path, line: match.line, col: match.col)
    }
}

/// What a go-to-definition click does.
package enum DefinitionOutcome: Equatable, Sendable {
    /// Exactly one place: open it (a kept tab), the cursor on the name.
    case jump(CodeNavLocation)
    /// Several: the menu at the click.
    case choose([DefinitionChoice])
    /// The index has no candidate: try the text-search heuristic.
    case searchText
    /// Nothing anywhere: a beep and "No definition of `word`".
    case notFound
}

/// Go to definition over the symbol index (spec §8.2): the symbols named
/// exactly like the word, nearest to the click first (same file → same
/// folder → same top-level folder → the rest), then by kind (types →
/// callables → the rest), then by path and line.
package enum DefinitionCandidates {
    package static func ordered(_ symbols: [CodeSymbol], from originPath: String) -> [CodeSymbol] {
        symbols.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            let nearA = nearness(of: a.path, to: originPath)
            let nearB = nearness(of: b.path, to: originPath)
            if nearA != nearB { return nearA < nearB }
            if a.kind.rankGroup != b.kind.rankGroup { return a.kind.rankGroup > b.kind.rankGroup }
            if a.path != b.path { return a.path < b.path }
            if a.line != b.line { return a.line < b.line }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    package static func outcome(for symbols: [CodeSymbol], from originPath: String) -> DefinitionOutcome {
        let ordered = ordered(symbols, from: originPath)
        switch ordered.count {
        case 0: return .searchText
        case 1: return .jump(DefinitionChoice(ordered[0]).target)
        default: return .choose(ordered.map(DefinitionChoice.init))
        }
    }

    /// 0 same file, 1 same folder, 2 same top-level folder, 3 the rest.
    package static func nearness(of path: String, to originPath: String) -> Int {
        if path == originPath { return 0 }
        let folder = folderPath(of: path)
        let originFolder = folderPath(of: originPath)
        if folder == originFolder { return 1 }
        if let top = folder.split(separator: "/").first, top == originFolder.split(separator: "/").first { return 2 }
        return 3
    }

    private static func folderPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The menu's first, disabled row.
    package static func menuHeader(word: String, count: Int, fromTextSearch: Bool) -> String {
        "\(word) — \(count) \(fromTextSearch ? "text matches" : "definitions")"
    }

    /// Shown above the editor for 2 s when nothing is found.
    package static func noDefinitionNotice(word: String) -> String {
        "No definition of `\(word)`"
    }
}

/// The text-search fallback (spec §6.5) over `code search --word --case`
/// results: lines that look like a definition of the word
/// (`func|function|def|fn|class|struct|interface|enum|type|proc|sub` then
/// the word) first, then every other occurrence; nearness to the click
/// orders each group, and the clicked occurrence itself is left out.
package enum DefinitionHeuristic {
    /// Matches asked of `code search`, and rows the menu shows at most.
    package static let searchMax = 200
    package static let menuCap = 30
    static let titleLimit = 120

    package static func looksLikeDefinition(_ line: String, word: String) -> Bool {
        let name = NSRegularExpression.escapedPattern(for: word)
        let pattern = #"\b(func|function|def|fn|class|struct|interface|enum|type|proc|sub)\s+"# + name + #"(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    package static func ranked(_ matches: [CodeSearchMatch], word: String, origin: CodeNavLocation) -> [CodeSearchMatch] {
        let width = word.utf16.count
        return matches
            .filter { match in
                !(match.path == origin.path && match.line == origin.line && (match.col..<match.col + max(width, 1)).contains(origin.col))
            }
            .enumerated()
            .map { offset, match in
                (match, looksLikeDefinition(match.text, word: word) ? 0 : 1, DefinitionCandidates.nearness(of: match.path, to: origin.path), offset)
            }
            .sorted { a, b in (a.1, a.2, a.3) < (b.1, b.2, b.3) }
            .map(\.0)
    }

    package static func outcome(for matches: [CodeSearchMatch], word: String, origin: CodeNavLocation) -> DefinitionOutcome {
        let ranked = ranked(matches, word: word, origin: origin)
        switch ranked.count {
        case 0: return .notFound
        case 1: return .jump(DefinitionChoice(ranked[0]).target)
        default: return .choose(ranked.prefix(menuCap).map(DefinitionChoice.init))
        }
    }
}
