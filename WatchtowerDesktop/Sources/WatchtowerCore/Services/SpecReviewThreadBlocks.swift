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
/// text: the thread shows a valid block as its card, and an invalid one as
/// a notice saying why (`rejected`), never as nothing.
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
    /// `rejected` holds, in reply order, why each closed block that is not
    /// valid was dropped (empty until final).
    package static func parse(
        _ text: String, final: Bool
    ) -> (text: String, question: String?, finding: SpecReviewProposedFinding?, rejected: [Rejection]) {
        guard text.contains(askAuthorFence) || text.contains(findingFence) else { return (text, nil, nil, []) }
        var removals: [Range<String.Index>] = []
        var question: String?
        var finding: SpecReviewProposedFinding?
        var rejected: [Rejection] = []
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
                switch checkQuestion(Data(body.utf8)) {
                case .success(let decoded): question = decoded
                case .failure(let problem):
                    rejected.append(Rejection(code: problem.code,
                                              notice: "The assistant's question to the author could not be sent: \(problem.reason)."))
                }
            default:
                switch checkFinding(Data(body.utf8)) {
                case .success(let decoded): finding = decoded
                case .failure(let problem):
                    rejected.append(Rejection(code: problem.code,
                                              notice: "The assistant's proposed finding could not be shown: \(problem.reason)."))
                }
            }
        }
        if !final {
            question = nil
            finding = nil
            rejected = []
        }
        guard !removals.isEmpty else { return (text, question, finding, rejected) }
        // Rebuilt from slices of the original, so every range stays valid.
        var visible = ""
        var kept = text.startIndex
        for range in removals {
            visible += text[kept..<range.lowerBound]
            kept = range.upperBound
        }
        visible += text[kept...]
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), question, finding, rejected)
    }

    /// Why a block was not valid: `code` is a fixed class for the log
    /// (FILES-01: never the model's words), `reason` the owner's words.
    package struct Problem: Error, Equatable {
        package let code: String
        package let reason: String
    }

    /// A dropped block: its class for the log, its notice for the thread.
    package struct Rejection: Equatable, Sendable {
        package let code: String
        package let notice: String
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
        try? checkQuestion(json).get()
    }

    package static func checkQuestion(_ json: Data) -> Result<String, Problem> {
        guard let raw = try? JSONDecoder().decode(RawQuestion.self, from: json) else {
            return .failure(Problem(code: "question_not_json", reason: "its block is not valid JSON with a question"))
        }
        let question = raw.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty { return .failure(Problem(code: "question_empty", reason: "the question is empty")) }
        if question.unicodeScalars.count > maxQuestionRunes {
            return .failure(Problem(code: "question_too_long", reason: "longer than \(maxQuestionRunes) characters"))
        }
        return .success(question)
    }

    /// A proposed finding with a known kind, a title and a text, and a quote
    /// from the document or the thread. Go checks the quotes themselves
    /// when the owner presses **Add to review**.
    package static func decodeFinding(_ json: Data) -> SpecReviewProposedFinding? {
        try? checkFinding(json).get()
    }

    package static func checkFinding(_ json: Data) -> Result<SpecReviewProposedFinding, Problem> {
        guard let finding = try? JSONDecoder().decode(SpecReviewProposedFinding.self, from: json) else {
            return .failure(Problem(code: "finding_not_json", reason: "its block is not valid JSON"))
        }
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !findingKinds.contains(finding.kind) {
            return .failure(Problem(
                code: "finding_unknown_kind",
                reason: "its kind \"\(finding.kind)\" is not differs, missing, decided_alone or blind_spot"))
        }
        if blank(finding.title) || blank(finding.text) {
            return .failure(Problem(code: "finding_no_title_or_text", reason: "it has no title or no text"))
        }
        if !["document", "thread"].contains(finding.quote.source) || blank(finding.quote.text) {
            return .failure(Problem(code: "finding_bad_quote", reason: "its quote has no source (document or thread) or no words"))
        }
        return .success(finding)
    }
}
