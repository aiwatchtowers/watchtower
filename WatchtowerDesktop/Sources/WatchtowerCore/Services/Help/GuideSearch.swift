import Foundation

/// Keyword ranking over guide sections; mirrors the Go ranker (internal/guide).
package enum GuideSearch {
    package static func rank(_ query: String, in sections: [GuideSection], limit: Int) -> [GuideSection] {
        let words = tokens(query).filter { $0.count >= 2 }
        guard !words.isEmpty, limit > 0 else { return [] }
        var scored: [(score: Int, index: Int)] = []
        for (index, section) in sections.enumerated() {
            let heading = tokens(section.heading)
            let title = tokens(section.pageTitle)
            let text = tokens(section.text)
            var score = 0
            for word in words {
                if heading.contains(where: { $0.hasPrefix(word) }) { score += 3 }
                if title.contains(where: { $0.hasPrefix(word) }) { score += 2 }
                if text.contains(where: { $0.hasPrefix(word) }) { score += 1 }
            }
            if score > 0 { scored.append((score, index)) }
        }
        // Stable on ties: the lower input index wins.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { sections[$0.index] }
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
