import Foundation

/// Open Quickly's scopes (spec §8.1). Text answers come from
/// `code search` (`CodeSearchRun`), not from the index.
package enum CodeSearchScope: String, CaseIterable, Sendable {
    case all, files, symbols, text
}

/// What lifts a match above an equally good one (spec §7): the workbench's
/// open tabs, its recently opened files (most recent first, the last 50)
/// and the files git reports modified.
package struct CodeRankingBoosts: Equatable, Sendable {
    package var openTabs: [String]
    package var recent: [String]
    package var gitModified: Set<String>

    package static let none = Self(openTabs: [], recent: [], gitModified: [])

    package init(openTabs: [String], recent: [String], gitModified: Set<String>) {
        self.openTabs = openTabs
        self.recent = Array(recent.prefix(50))
        self.gitModified = gitModified
    }
}

/// One match to rank: its fuzzy score, the file it is in, and its kind
/// (nil for a file).
package struct CodeRankCandidate: Equatable, Sendable {
    package let score: Int
    package let path: String
    package let kind: CodeSymbolKind?

    package init(score: Int, path: String, kind: CodeSymbolKind?) {
        self.score = score
        self.path = path
        self.kind = kind
    }
}

/// One row of Open Quickly's Files/Symbols results.
package struct CodeQuickResult: Equatable, Identifiable, Sendable {
    package enum Item: Equatable, Hashable, Sendable {
        case file(path: String)
        case symbol(CodeSymbol)
    }

    package let item: Item
    /// The fuzzy score plus the ranking boosts.
    package let score: Int
    /// UTF-16 offsets of the matched units in `title`.
    package let titleMatches: [Int]
    /// A file matched across folders: UTF-16 offsets in its path; else empty.
    package let pathMatches: [Int]

    package init(item: Item, score: Int, titleMatches: [Int], pathMatches: [Int]) {
        self.item = item
        self.score = score
        self.titleMatches = titleMatches
        self.pathMatches = pathMatches
    }

    /// The file's name, or the symbol's.
    package var title: String {
        switch item {
        case let .file(path): CodeRanking.fileName(path)
        case let .symbol(symbol): symbol.name
        }
    }

    package var path: String {
        switch item {
        case let .file(path): path
        case let .symbol(symbol): symbol.path
        }
    }

    package var id: String {
        switch item {
        case let .file(path): "file:\(path)"
        case let .symbol(s): "symbol:\(s.path):\(s.line):\(s.col):\(s.name)"
        }
    }
}

/// Ranking of Open Quickly's matches (spec §7). Pure.
package enum CodeRanking {
    /// Added per boost tier (open tab 3, recent 2, git modified 1): enough
    /// to order near-equal matches, not to lift a poor match over a good one.
    package static let tierBonus = 12
    /// Added per kind group (types 2, callables 1).
    package static let kindBonus = 4

    /// Indices of `candidates`, best first; equal totals keep input order.
    package static func rank(_ candidates: [CodeRankCandidate], boosts: CodeRankingBoosts) -> [Int] {
        let tiers = CodeBoostTiers(boosts)
        var ranked = CodeTopRanked(limit: candidates.count)
        for (i, candidate) in candidates.enumerated() {
            let total = candidate.score + tiers.tier(of: candidate.path) * tierBonus + (candidate.kind?.rankGroup ?? 0) * kindBonus
            ranked.offer(total: total, entry: i, symbol: -1)
        }
        return ranked.best().map(\.entry)
    }

    /// An empty query: open tabs in tab order, then recent files by recency,
    /// then git-modified files, then the rest — each in `files` order where
    /// not given, and only paths `files` holds.
    package static func emptyQueryOrder(files: [String], boosts: CodeRankingBoosts) -> [String] {
        let present = Set(files)
        var seen = Set<String>()
        var out: [String] = []
        for path in boosts.openTabs + boosts.recent where present.contains(path) && seen.insert(path).inserted {
            out.append(path)
        }
        for path in files where boosts.gitModified.contains(path) && seen.insert(path).inserted {
            out.append(path)
        }
        for path in files where seen.insert(path).inserted {
            out.append(path)
        }
        return out
    }

    /// The last path component.
    package static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// `CodeRankingBoosts` as sets, built once per query.
struct CodeBoostTiers {
    private let open: Set<String>
    private let recent: Set<String>
    private let git: Set<String>

    init(_ boosts: CodeRankingBoosts) {
        open = Set(boosts.openTabs)
        recent = Set(boosts.recent)
        git = boosts.gitModified
    }

    func tier(of path: String) -> Int {
        if open.contains(path) { return 3 }
        if recent.contains(path) { return 2 }
        return git.contains(path) ? 1 : 0
    }
}
