import Foundation

/// Keyword ranking over guide sections; mirrors the Go ranker (internal/userguide).
/// Each query word adds only its best match: 3 heading word prefix, else 2 page-title
/// word prefix, else 1 text contains. Words are lowercased, split on whitespace, trimmed of non-letter/digit edges; words under 2 chars drop.
package enum GuideSearch {
    package static func rank(_ query: String, in sections: [GuideSection], limit: Int) -> [GuideSection] {
        let words = Self.words(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        var scored: [(score: Int, index: Int)] = []
        for (index, section) in sections.enumerated() {
            let heading = Self.words(section.heading)
            let title = Self.words(section.pageTitle)
            let text = section.text.lowercased()
            var score = 0
            for word in words {
                if heading.contains(where: { $0.hasPrefix(word) }) {
                    score += 3
                } else if title.contains(where: { $0.hasPrefix(word) }) {
                    score += 2
                } else if text.contains(word) {
                    score += 1
                }
            }
            if score > 0 { scored.append((score, index)) }
        }
        // Stable on ties: the lower input index wins.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { sections[$0.index] }
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = trimEdges(raw)
            return word.count >= 2 ? word : nil
        }
    }

    private static func trimEdges(_ raw: Substring) -> String {
        var chars = Array(raw)
        while let first = chars.first, !first.isLetter && !first.isNumber { chars.removeFirst() }
        while let last = chars.last, !last.isLetter && !last.isNumber { chars.removeLast() }
        return String(chars)
    }
}
