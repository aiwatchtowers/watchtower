import Foundation

/// Marks to the review answer. Only `comment` marks are sent: "Fine as is"
/// and "Viewed" never reach the author. Every comment carries a heading and
/// quote located in the RENDERED snapshot, the text a closed ask re-locates
/// its comments on (`internal/asks/answer.go` is unchanged).
///
/// The one builder of every answer to a review ask (F5): the Desktop's
/// answer path (`OwnerAsksViewModel.answer(_:with:)`, which the drawer's
/// footer, the findings screen, Quick answers and the phone's relay all
/// end in) reads `spec_review_marks` at answer time and appends these
/// comments, whether or not a findings screen was ever loaded.
package enum SpecReviewAnswer {
    /// `base` is the answer as written — the draft's margin comments made
    /// under **Read the spec**, its question answers, its note, its
    /// verdict — with the marks' comments after its own; a `verdict`
    /// replaces the base's. `rendered` hands over the snapshot already
    /// rendered (a caller's cache); nil renders it here.
    ///
    /// `loop` is the ledger of a review whose author loop ended (spec
    /// 2026-10-26 §7): the comments are then the loop's (`loopComments`)
    /// and the verdict is always `approved`.
    package static func build(
        result: SpecReviewResult?,
        marks: [String: SpecReviewMark],
        loop: [SpecReviewLedgerEntry]? = nil,
        base: OwnerAskAnswer = OwnerAskAnswer(),
        verdict: OwnerAskAnswer.Verdict? = nil,
        snapshot: String,
        rendered: (() -> RenderedDocument)? = nil
    ) -> OwnerAskAnswer {
        var answer = base
        if let verdict { answer.verdict = verdict }
        if let loop {
            answer.verdict = .approved
            answer.comments += loopComments(
                ledger: loop, result: result, marks: marks, snapshot: snapshot, rendered: rendered
            )
            return answer
        }
        answer.comments += comments(result: result, marks: marks, snapshot: snapshot, rendered: rendered)
        return answer
    }

    /// A finished loop's comments, in ledger order: each `comment` mark on a
    /// ledger key — **Reviewer is right** on a dispute, **Reopen** on a fix —
    /// anchored at the entry's `where`, else its finding's chapter heading,
    /// else the document's first heading. `ok` marks (**Author is right**)
    /// and unpicked disputes send nothing.
    package static func loopComments(
        ledger: [SpecReviewLedgerEntry],
        result: SpecReviewResult?,
        marks: [String: SpecReviewMark],
        snapshot: String,
        rendered render: (() -> RenderedDocument)? = nil
    ) -> [OwnerAskAnswer.Comment] {
        let marked = ledger.filter { marks[$0.item.key]?.state == .comment }
        guard !marked.isEmpty else { return [] }
        let rendered = render?() ?? DocumentRendering.render(snapshot)
        return marked.compactMap { entry in
            guard let mark = marks[entry.item.key] else { return nil }
            let chapter = result?.findings.first { $0.key == entry.item.key }?.chapter
            let anchor = entry.item.anchor.flatMap { $0.quote.isEmpty ? nil : ($0.heading, $0.quote) }
                ?? result.flatMap { r in chapter.flatMap { chapterAnchor(result: r, key: $0, snapshot: snapshot) } }
                ?? firstHeadingAnchor(snapshot)
            return comment(heading: anchor.0, quote: anchor.1, body: loopBody(entry, owner: mark.body), in: rendered)
        }
    }

    /// "Reviewer is right: <text> — <verdict note>" for a dispute,
    /// "Reopened: <text>" for a fix the owner reopened; the owner's words
    /// after a blank line when given.
    package static func loopBody(_ entry: SpecReviewLedgerEntry, owner body: String) -> String {
        let text = entry.item.text
        let head: String
        if entry.verdict == "resolved" {
            head = "Reopened: \(text)"
        } else {
            let note = entry.verdictNote.trimmingCharacters(in: .whitespacesAndNewlines)
            head = note.isEmpty ? "Reviewer is right: \(text)" : "Reviewer is right: \(text) — \(note)"
        }
        let owner = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? head : "\(head)\n\n\(owner)"
    }

    /// The comments the marks give, in findings order, then the comments of
    /// findings the re-run no longer has. No result (the reviewer queued,
    /// running or failed) makes every comment mark such an orphan: it goes
    /// out as "From the previous run" with its finding text (`about`). The
    /// snapshot is rendered (or `rendered` called) only when there is a
    /// comment to place.
    package static func comments(
        result: SpecReviewResult?,
        marks: [String: SpecReviewMark],
        snapshot: String,
        rendered render: (() -> RenderedDocument)? = nil
    ) -> [OwnerAskAnswer.Comment] {
        let marked = result?.findings.filter { marks[$0.key]?.state == .comment } ?? []
        let orphans = orphanMarks(result: result, marks: marks)
        guard !marked.isEmpty || !orphans.isEmpty else { return [] }
        let rendered = render?() ?? DocumentRendering.render(snapshot)
        var comments: [OwnerAskAnswer.Comment] = []
        for finding in marked {
            guard let mark = marks[finding.key] else { continue }
            let anchor = finding.anchor.map { ($0.heading, $0.quote) }
                ?? result.flatMap { chapterAnchor(result: $0, key: finding.chapter, snapshot: snapshot) }
                ?? firstHeadingAnchor(snapshot)
            comments.append(comment(
                heading: anchor.0, quote: anchor.1, body: join(finding.text, mark.body), in: rendered
            ))
        }
        let anchor = firstHeadingAnchor(snapshot)
        for mark in orphans {
            let about = mark.about.isEmpty ? mark.body : join(mark.about, mark.body)
            comments.append(comment(
                heading: anchor.0, quote: anchor.1, body: "From the previous run: \(about)", in: rendered
            ))
        }
        return comments
    }

    /// Comment marks whose key the result no longer has (the reviewer ran
    /// again, or has no result now), in key order. `viewed` marks of
    /// dropped chapters are not orphans: nothing is lost by forgetting them.
    package static func orphanMarks(
        result: SpecReviewResult?,
        marks: [String: SpecReviewMark]
    ) -> [SpecReviewMark] {
        let known = Set(result?.findings.map(\.key) ?? [])
        return marks.values
            .filter { $0.state == .comment && !known.contains($0.key) }
            .sorted { $0.key < $1.key }
    }

    private static func join(_ text: String, _ body: String) -> String {
        let owner = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? text : "\(text) — \(owner)"
    }

    /// The anchor as the closed ask re-locates it: the quote found in the
    /// rendered snapshot (as written, else rendered), with the rendered
    /// text around it and the rendered heading before it. A quote not found
    /// keeps the reviewer's heading and quote, with no context.
    private static func comment(
        heading: String, quote: String, body: String, in rendered: RenderedDocument
    ) -> OwnerAskAnswer.Comment {
        var anchor = CommentAnchor(quote: quote, prefix: "", suffix: "", heading: heading)
        if let hit = OwnerAskReviewText.range(ofQuote: quote, in: rendered),
           let range = Range(hit, in: rendered.text) {
            let made = CommentAnchor.make(text: rendered.text, range: range, headings: rendered.headingOffsets)
            anchor = CommentAnchor(
                quote: made.quote, prefix: made.prefix, suffix: made.suffix,
                heading: made.heading.isEmpty ? plainTitle(heading) : made.heading
            )
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
