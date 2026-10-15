import Foundation

/// Line comments of the diff reviewer anchored by their quoted lines and
/// re-placed on a later version of the file (REVIEW-03), on top of the
/// artifact comments' `CommentAnchor` (exact match, then whitespace-collapsed).
package enum ReviewCommentAnchor {
    package struct Placement: Equatable, Sendable {
        package let startLine: Int
        package let endLine: Int
        package init(startLine: Int, endLine: Int) { self.startLine = startLine; self.endLine = endLine }
    }

    package struct Plan: Equatable, Sendable {
        package var moved: [Int64: Placement]
        package var lost: Set<Int64>
        package init(moved: [Int64: Placement] = [:], lost: Set<Int64> = []) { self.moved = moved; self.lost = lost }
    }

    /// The anchor of lines startLine...endLine (1-based) of text.
    package static func anchor(text: String, startLine: Int, endLine: Int) -> CommentAnchor {
        guard let range = range(ofLines: startLine...max(startLine, endLine), in: text) else {
            return CommentAnchor(quote: "", prefix: "", suffix: "", heading: "")
        }
        return CommentAnchor.make(text: text, range: range, headings: [])
    }

    /// Where each line comment lands in its file's new text; a design comment
    /// (no path) is left alone.
    package static func plan(_ comments: [ReviewComment], textFor: (String) -> String?) -> Plan {
        var plan = Plan()
        for c in comments {
            guard let path = c.path else { continue }
            let anchor = CommentAnchor(quote: c.quote, prefix: c.quotePrefix, suffix: c.quoteSuffix, heading: "")
            guard let text = textFor(path), let found = anchor.locate(in: text) else {
                plan.lost.insert(c.id)
                continue
            }
            let start = line(at: found.lowerBound, in: text)
            let lastChar = found.isEmpty ? found.lowerBound : text.index(before: found.upperBound)
            plan.moved[c.id] = Placement(startLine: start, endLine: line(at: lastChar, in: text))
        }
        return plan
    }

    static func range(ofLines lines: ClosedRange<Int>, in text: String) -> Range<String.Index>? {
        var starts = [text.startIndex]
        var i = text.startIndex
        while let nl = text[i...].firstIndex(of: "\n") {
            i = text.index(after: nl)
            starts.append(i)
        }
        guard lines.lowerBound >= 1, lines.lowerBound <= starts.count else { return nil }
        let lo = starts[lines.lowerBound - 1]
        let hiLine = min(lines.upperBound, starts.count)
        var hi = hiLine < starts.count ? text.index(before: starts[hiLine]) : text.endIndex
        if hi < lo { hi = lo }
        return lo..<hi
    }

    static func line(at index: String.Index, in text: String) -> Int {
        text[text.startIndex..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
