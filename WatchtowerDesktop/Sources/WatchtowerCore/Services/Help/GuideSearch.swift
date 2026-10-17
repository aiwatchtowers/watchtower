import Foundation

/// Keyword ranking over guide sections; mirrors the Go ranker (internal/userguide/search.go),
/// and internal/userguide/testdata/queries.json holds both to the same stopwords and results.
/// Query words are the question's words minus `stopwords`. Per query word a section adds
/// 3 when a heading word starts with it, 2 when a page-title word does and 1 when a text
/// word does — all that apply. Words are lowercased (’ becomes '), split on whitespace,
/// trimmed of non-letter/digit edges and a possessive 's; words under 2 chars drop.
package enum GuideSearch {
    /// Sections with their words split once, so ranking on every keystroke
    /// does not re-split the whole guide.
    package struct Searchable: Sendable {
        fileprivate struct Words: Sendable {
            let heading: [String]
            let title: [String]
            let text: [String]
        }

        package let sections: [GuideSection]
        fileprivate let words: [Words]

        package init(_ sections: [GuideSection]) {
            self.sections = sections
            words = sections.map {
                Words(heading: GuideSearch.words($0.heading), title: GuideSearch.words($0.pageTitle),
                      text: GuideSearch.words($0.text))
            }
        }
    }

    package static func rank(_ query: String, in sections: [GuideSection], limit: Int) -> [GuideSection] {
        rank(query, in: Searchable(sections), limit: limit)
    }

    package static func rank(_ query: String, in searchable: Searchable, limit: Int) -> [GuideSection] {
        let words = Self.words(query).filter { !stopwords.contains($0) }
        guard !words.isEmpty, limit > 0 else { return [] }
        var scored: [(score: Int, index: Int)] = []
        for (index, section) in searchable.words.enumerated() {
            var score = 0
            for word in words {
                if section.heading.contains(where: { $0.hasPrefix(word) }) { score += 3 }
                if section.title.contains(where: { $0.hasPrefix(word) }) { score += 2 }
                if section.text.contains(where: { $0.hasPrefix(word) }) { score += 1 }
            }
            if score > 0 { scored.append((score, index)) }
        }
        // Stable on ties: the lower input index wins.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { searchable.sections[$0.index] }
    }

    /// English filler that carries no topic; the same list as Go's `stopwordList`.
    static let stopwords: Set<String> = Set("""
        a about after again all also am an and any are as at be been before being
        but by can can't could did didn't do does doesn't doing don't done for from get gets getting got
        had has have having he her here him his how i i'm if in into is isn't it it's its just me might
        more most must my need needs no not of off on one only or our out own please set sets setting
        should so some such than that the their them then there these they this those to too up us use
        used uses using very via want wants was way we were what when where which who whom whose why will
        with without would yes you your
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    fileprivate static func words(_ s: String) -> [String] {
        let normalized = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return normalized.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var word = trimEdges(raw)
            if word.hasSuffix("'s") { word.removeLast(2) }
            return word.count >= 2 ? word : nil
        }
    }

    private static func trimEdges(_ raw: Substring) -> String {
        let isEdge: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        guard let start = raw.firstIndex(where: { !isEdge($0) }),
              let end = raw.lastIndex(where: { !isEdge($0) }) else { return "" }
        return String(raw[start...end])
    }
}
