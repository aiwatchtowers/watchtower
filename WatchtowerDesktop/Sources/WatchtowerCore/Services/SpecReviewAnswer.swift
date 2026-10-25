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

    /// The chapter heading (no `#`s) with the chapter's first body line as the
    /// quote. Offsets are UTF-8 bytes; an unknown chapter or bad range is nil.
    private static func chapterAnchor(
        result: SpecReviewResult, key: String, snapshot: String
    ) -> (String, String)? {
        guard let chapter = result.chapters.first(where: { $0.key == key }) else { return nil }
        let bytes = snapshot.utf8
        guard chapter.start >= 0, chapter.start <= chapter.end, chapter.end <= bytes.count else { return nil }
        let from = bytes.index(bytes.startIndex, offsetBy: chapter.start)
        let to = bytes.index(bytes.startIndex, offsetBy: chapter.end)
        guard let slice = String(bytes[from..<to]) else { return nil }
        return headingAndQuote(slice, fallbackHeading: chapter.heading)
    }

    /// The document's first heading and that section's first body line; with
    /// no heading, no heading and the first body line of the document.
    private static func firstHeadingAnchor(_ snapshot: String) -> (String, String) {
        var inFence = false
        var offset = 0
        for line in snapshot.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, headingTitle(trimmed) != nil {
                let rest = snapshot.index(snapshot.startIndex, offsetBy: offset)
                return headingAndQuote(String(snapshot[rest...]), fallbackHeading: "")
            }
            offset += line.count + 1
        }
        return headingAndQuote(snapshot, fallbackHeading: "")
    }

    /// Anchors match the document as rendered, where the markers are gone:
    /// the heading is its title and the quote the first body line (heading
    /// lines and fenced code skipped), leading list/quote markers and inline
    /// emphasis rendered away. A section with no body line quotes its title.
    private static func headingAndQuote(_ slice: String, fallbackHeading: String) -> (String, String) {
        var heading = ""
        var inFence = false
        for line in slice.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || trimmed.isEmpty { continue }
            if let title = headingTitle(trimmed) {
                if heading.isEmpty { heading = title }
                continue
            }
            if let quote = renderedQuote(trimmed) {
                return (heading.isEmpty ? plainTitle(fallbackHeading) : heading, quote)
            }
        }
        let title = heading.isEmpty ? plainTitle(fallbackHeading) : heading
        return (title, title)
    }

    private static func plainTitle(_ heading: String) -> String {
        String(heading.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// The title of an ATX heading line ("## Title"), else nil.
    private static func headingTitle(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func renderedQuote(_ line: String) -> String? {
        var text = Substring(line)
        while let first = text.first, first == ">" || first == " " { text = text.dropFirst() }
        if let first = text.first, "-*+".contains(first), text.dropFirst().first == " " {
            text = text.dropFirst(2)
        } else if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty,
                  text[text.index(after: dot)...].first == " " {
            text = text[text.index(dot, offsetBy: 2)...]
        }
        let rendered = DocumentRendering.render(String(text)).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = rendered.split(whereSeparator: \.isNewline).first else { return nil }
        let quote = first.trimmingCharacters(in: .whitespaces)
        return quote.isEmpty ? nil : quote
    }
}
