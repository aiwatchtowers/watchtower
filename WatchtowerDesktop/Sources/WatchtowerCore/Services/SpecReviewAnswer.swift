import Foundation

/// Marks to the review answer. Only `comment` marks are sent: "Fine as is"
/// and "Viewed" never reach the author. Every comment carries a heading and
/// quote that exist in the snapshot (`internal/asks/answer.go` is unchanged).
package enum SpecReviewAnswer {
    package static func build(
        result: SpecReviewResult,
        marks: [String: SpecReviewMark],
        note: String,
        verdict: OwnerAskAnswer.Verdict,
        snapshot: String
    ) -> OwnerAskAnswer {
        var comments: [OwnerAskAnswer.Comment] = []
        for finding in result.findings {
            guard let mark = marks[finding.key], mark.state == .comment else { continue }
            let anchor = finding.anchor.map { ($0.heading, $0.quote) }
                ?? chapterAnchor(result: result, key: finding.chapter, snapshot: snapshot)
                ?? firstHeadingAnchor(snapshot)
            comments.append(comment(
                heading: anchor.0, quote: anchor.1, body: join(finding.text, mark.body), snapshot: snapshot
            ))
        }
        let anchor = firstHeadingAnchor(snapshot)
        for mark in orphanMarks(result: result, marks: marks) where mark.state == .comment {
            comments.append(comment(
                heading: anchor.0, quote: anchor.1, body: "From the previous run: \(mark.body)", snapshot: snapshot
            ))
        }
        return OwnerAskAnswer(verdict: verdict, comments: comments, note: note)
    }

    /// Comment marks whose key the result no longer has (the reviewer ran
    /// again), in key order. `viewed` marks of dropped chapters are not
    /// orphans: nothing is lost by forgetting them.
    package static func orphanMarks(
        result: SpecReviewResult,
        marks: [String: SpecReviewMark]
    ) -> [SpecReviewMark] {
        let known = Set(result.findings.map(\.key))
        return marks.values
            .filter { $0.state == .comment && !known.contains($0.key) }
            .sorted { $0.key < $1.key }
    }

    private static func join(_ text: String, _ body: String) -> String {
        let owner = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? text : "\(text) — \(owner)"
    }

    private static func comment(
        heading: String, quote: String, body: String, snapshot: String
    ) -> OwnerAskAnswer.Comment {
        var anchor = CommentAnchor(quote: quote, prefix: "", suffix: "", heading: heading)
        if !quote.isEmpty, let range = snapshot.range(of: quote) {
            let made = CommentAnchor.make(text: snapshot, range: range, headings: [])
            anchor.prefix = made.prefix
            anchor.suffix = made.suffix
        }
        return OwnerAskAnswer.Comment(anchor: anchor, body: body)
    }

    /// The chapter heading with the chapter's first non-blank line as quote.
    /// Offsets are UTF-8 bytes; an unknown chapter or bad range is nil.
    private static func chapterAnchor(
        result: SpecReviewResult, key: String, snapshot: String
    ) -> (String, String)? {
        guard let chapter = result.chapters.first(where: { $0.key == key }) else { return nil }
        let bytes = snapshot.utf8
        guard chapter.start >= 0, chapter.start <= chapter.end, chapter.end <= bytes.count else { return nil }
        let from = bytes.index(bytes.startIndex, offsetBy: chapter.start)
        let to = bytes.index(bytes.startIndex, offsetBy: chapter.end)
        guard let slice = String(bytes[from..<to]) else { return nil }
        guard let line = firstNonBlankLine(slice) else { return nil }
        return (chapter.heading, line)
    }

    private static func firstNonBlankLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The document's first heading line (title without its `#`s) and the
    /// line itself; with no heading, no heading and the first non-blank line.
    private static func firstHeadingAnchor(_ snapshot: String) -> (String, String) {
        let lines = snapshot.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.hasPrefix("#") }) {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return (title, line)
        }
        return ("", lines.first { !$0.isEmpty } ?? "")
    }
}
