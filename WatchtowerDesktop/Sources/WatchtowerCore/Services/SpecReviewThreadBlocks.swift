import Foundation

/// The two fenced blocks a Discuss thread's agent may end a reply with
/// (spec 2026-11-08 §3; Go `specreview.AskAuthorFence`/`FindingFence`,
/// `internal/specreview/testdata/thread_blocks` is the shared fixture):
///
/// - ```` ```watchtower-ask-author ```` — `{"question": "…"}`, one question
///   only the author can answer;
/// - ```` ```watchtower-finding ```` — a proposed finding (Go's
///   `ThreadFindingInput`: `kind`, `severity`, `title`, `text`, `quote`
///   `{source, text}`, `where`).
///
/// The rules are `ChatQuestionParser`'s: the last valid block of each fence
/// wins (a broken later block never replaces an earlier valid one), and an
/// unclosed block is hidden while the reply streams. Unlike a question card,
/// every closed block of these two fences — valid or not — leaves the shown
/// text: the thread shows a block as its card, or as nothing.
package enum SpecReviewThreadBlocks {
    package static let askAuthorFence = "```watchtower-ask-author"
    package static let findingFence = "```watchtower-finding"

    /// Go's `maxQuestionRunes` for `spec-review question`: a longer one
    /// would be refused there, so it is no question here.
    package static let maxQuestionRunes = 1000

    /// The finding kinds Go's `ValidateThreadFinding` accepts.
    package static let findingKinds: Set<String> = ["differs", "missing", "decided_alone", "blind_spot"]

    /// `final`: the reply is complete. Until then no block is read and an
    /// unclosed one is hidden; once final, an unclosed block stays visible.
    package static func parse(
        _ text: String, final: Bool
    ) -> (text: String, question: String?, finding: SpecReviewProposedFinding?) {
        guard text.contains(askAuthorFence) || text.contains(findingFence) else { return (text, nil, nil) }
        var removals: [Range<String.Index>] = []
        var question: String?
        var finding: SpecReviewProposedFinding?
        var cursor = text.startIndex
        while let (open, fence) = nextFence(in: text, from: cursor) {
            cursor = open.upperBound
            let lineEnd = text[open.upperBound...].firstIndex(of: "\n")
            // The fence's name must end its line: ```watchtower-findings is
            // no block of ours.
            guard text[open.upperBound..<(lineEnd ?? text.endIndex)].allSatisfy(\.isWhitespace) else { continue }
            guard let lineEnd, let close = closingFence(in: text, from: lineEnd) else {
                if !final { removals.append(open.lowerBound..<text.endIndex) }
                break
            }
            let body = close.lowerBound > lineEnd ? String(text[text.index(after: lineEnd)..<close.lowerBound]) : ""
            cursor = close.upperBound
            removals.append(open.lowerBound..<close.upperBound)
            switch fence {
            case askAuthorFence:
                if let decoded = decodeQuestion(Data(body.utf8)) { question = decoded }
            default:
                if let decoded = decodeFinding(Data(body.utf8)) { finding = decoded }
            }
        }
        if !final {
            question = nil
            finding = nil
        }
        guard !removals.isEmpty else { return (text, question, finding) }
        // Rebuilt from slices of the original, so every range stays valid.
        var visible = ""
        var kept = text.startIndex
        for range in removals {
            visible += text[kept..<range.lowerBound]
            kept = range.upperBound
        }
        visible += text[kept...]
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), question, finding)
    }

    /// The first of the two fences at or after `cursor` that starts a line.
    private static func nextFence(
        in text: String, from cursor: String.Index
    ) -> (Range<String.Index>, String)? {
        var from = cursor
        while from < text.endIndex {
            let candidates = [askAuthorFence, findingFence].compactMap { fence in
                text.range(of: fence, range: from..<text.endIndex).map { ($0, fence) }
            }
            guard let first = candidates.min(by: { $0.0.lowerBound < $1.0.lowerBound }) else { return nil }
            if first.0.lowerBound == text.startIndex || text[text.index(before: first.0.lowerBound)] == "\n" {
                return first
            }
            from = first.0.upperBound
        }
        return nil
    }

    /// The line that is exactly ``` after `start` (a newline); its range
    /// covers the leading newline and the fence.
    private static func closingFence(in text: String, from start: String.Index) -> Range<String.Index>? {
        var cursor = start
        while let found = text.range(of: "\n```", range: cursor..<text.endIndex) {
            if found.upperBound == text.endIndex || text[found.upperBound] == "\n" { return found }
            cursor = found.upperBound
        }
        return nil
    }

    private struct RawQuestion: Decodable {
        let question: String
    }

    /// `{"question": "…"}`: a question that is not blank and fits Go's cap.
    package static func decodeQuestion(_ json: Data) -> String? {
        guard let raw = try? JSONDecoder().decode(RawQuestion.self, from: json) else { return nil }
        let question = raw.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.unicodeScalars.count <= maxQuestionRunes else { return nil }
        return question
    }

    /// A proposed finding with a known kind, a title and a text, and a quote
    /// from the document or the thread. Go checks the quotes themselves
    /// when the owner presses **Add to review**.
    package static func decodeFinding(_ json: Data) -> SpecReviewProposedFinding? {
        guard let finding = try? JSONDecoder().decode(SpecReviewProposedFinding.self, from: json) else { return nil }
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard findingKinds.contains(finding.kind), !blank(finding.title), !blank(finding.text),
              ["document", "thread"].contains(finding.quote.source), !blank(finding.quote.text) else { return nil }
        return finding
    }
}
