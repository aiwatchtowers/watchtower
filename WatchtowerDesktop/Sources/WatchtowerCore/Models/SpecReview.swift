import Foundation
import GRDB

/// The spec reviewer's stored result (Go `specreview.Result`, pinned by
/// `internal/specreview/testdata/result_keys.golden`). Decoding tolerates
/// unknown keys and missing optional ones; enums stay strings so a value this
/// build does not know is shown neutrally instead of failing the screen.
package struct SpecReviewResult: Decodable, Equatable, Sendable {
    package struct Anchor: Decodable, Equatable, Sendable {
        package var heading: String
        package var quote: String

        package init(heading: String, quote: String) {
            self.heading = heading
            self.quote = quote
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            heading = try c.decodeIfPresent(String.self, forKey: .heading) ?? ""
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        }

        private enum Keys: String, CodingKey { case heading, quote }
    }

    package struct Source: Decodable, Equatable, Sendable {
        package var kind: String
        package var ref: String
        package var quote: String
        /// "owner" or "agent"; empty when the result predates the key.
        package var speaker: String

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        }

        private enum Keys: String, CodingKey { case kind, ref, quote, speaker }
    }

    package struct Evidence: Decodable, Equatable, Sendable {
        package var path: String
        package var line: Int

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        }

        private enum Keys: String, CodingKey { case path, line }
    }

    /// One agreed point compared with the document. `status`: as_agreed,
    /// differs or missing (other values kept as read).
    package struct Agreement: Decodable, Equatable, Sendable {
        package var key: String
        package var text: String
        package var status: String
        package var note: String
        package var chapter: String
        package var source: Source?
        package var anchor: Anchor?

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
            source = try c.decodeIfPresent(Source.self, forKey: .source)
            anchor = try c.decodeIfPresent(Anchor.self, forKey: .anchor)
        }

        private enum Keys: String, CodingKey {
            case key, text, status, note, chapter, source
            case anchor = "where"
        }
    }

    package struct DecidedAlone: Decodable, Equatable, Sendable {
        package var key: String
        package var text: String
        package var note: String
        package var chapter: String
        package var anchor: Anchor?

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
            anchor = try c.decodeIfPresent(Anchor.self, forKey: .anchor)
        }

        private enum Keys: String, CodingKey {
            case key, text, note, chapter
            case anchor = "where"
        }
    }

    package struct BlindSpot: Decodable, Equatable, Sendable {
        package var key: String
        package var text: String
        package var why: String
        package var chapter: String
        package var anchor: Anchor?
        package var evidence: Evidence?

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
            chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
            anchor = try c.decodeIfPresent(Anchor.self, forKey: .anchor)
            evidence = try c.decodeIfPresent(Evidence.self, forKey: .evidence)
        }

        private enum Keys: String, CodingKey {
            case key, text, why, chapter, evidence
            case anchor = "where"
        }
    }

    /// One lens question answered for a chapter. `answer`: ok, concern, n/a.
    package struct Check: Decodable, Equatable, Sendable {
        package var key: String
        package var chapter: String
        package var lens: String
        package var question: String
        package var answer: String
        package var note: String

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
            lens = try c.decodeIfPresent(String.self, forKey: .lens) ?? ""
            question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
            answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        }

        private enum Keys: String, CodingKey { case key, chapter, lens, question, answer, note }
    }

    /// A comment of the previous round. `status`: resolved or open.
    package struct Resolved: Decodable, Equatable, Sendable {
        package var commentQuote: String
        package var status: String
        package var note: String

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            commentQuote = try c.decodeIfPresent(String.self, forKey: .commentQuote) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        }

        private enum Keys: String, CodingKey {
            case status, note
            case commentQuote = "comment_quote"
        }
    }

    /// The owner's idea against the document's goal. `verdict`: matches,
    /// narrowed or differs.
    package struct Idea: Decodable, Equatable, Sendable {
        package var ownerQuote: String
        package var goalQuote: String
        package var verdict: String
        package var note: String
        package var ownerSource: Source?

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            ownerQuote = try c.decodeIfPresent(String.self, forKey: .ownerQuote) ?? ""
            goalQuote = try c.decodeIfPresent(String.self, forKey: .goalQuote) ?? ""
            verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            ownerSource = try c.decodeIfPresent(Source.self, forKey: .ownerSource)
        }

        /// Neither the owner's words nor the document's goal: nothing to show.
        var isBlank: Bool {
            ownerQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && goalQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private enum Keys: String, CodingKey {
            case verdict, note
            case ownerQuote = "owner_quote"
            case goalQuote = "goal_quote"
            case ownerSource = "owner_source"
        }
    }

    /// A slice of the snapshot: `start`/`end` are UTF-8 byte offsets.
    package struct Chapter: Decodable, Equatable, Sendable {
        package var key: String
        package var heading: String
        package var start: Int
        package var end: Int

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            heading = try c.decodeIfPresent(String.self, forKey: .heading) ?? ""
            start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 0
            end = try c.decodeIfPresent(Int.self, forKey: .end) ?? 0
        }

        private enum Keys: String, CodingKey { case key, heading, start, end }
    }

    package var summary: String
    package var idea: Idea?
    package var agreements: [Agreement]
    package var decidedAlone: [DecidedAlone]
    package var blindSpots: [BlindSpot]
    package var checks: [Check]
    package var resolved: [Resolved]
    package var chapters: [Chapter]
    package var notes: [String]
    package var codeRead: Bool
    package var dropped: Int

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        // An idea with neither quote is absent: a result stored before Go
        // left the key out wrote an empty one (F2).
        idea = try c.decodeIfPresent(Idea.self, forKey: .idea).flatMap { $0.isBlank ? nil : $0 }
        agreements = try c.decodeIfPresent([Agreement].self, forKey: .agreements) ?? []
        decidedAlone = try c.decodeIfPresent([DecidedAlone].self, forKey: .decidedAlone) ?? []
        blindSpots = try c.decodeIfPresent([BlindSpot].self, forKey: .blindSpots) ?? []
        checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
        resolved = try c.decodeIfPresent([Resolved].self, forKey: .resolved) ?? []
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        codeRead = try c.decodeIfPresent(Bool.self, forKey: .codeRead) ?? false
        dropped = try c.decodeIfPresent(Int.self, forKey: .dropped) ?? 0
    }

    private enum Keys: String, CodingKey {
        case summary, idea, agreements, checks, resolved, chapters, notes, dropped
        case decidedAlone = "decided_alone"
        case blindSpots = "blind_spots"
        case codeRead = "code_read"
    }
}

/// One finding the owner can mark, whatever its kind.
package struct SpecReviewFinding: Equatable, Sendable {
    package var key: String
    package var chapter: String
    package var text: String
    package var anchor: SpecReviewResult.Anchor?
}

extension SpecReviewResult {
    /// Agreements, decided-alone items, blind spots and checks (text = the
    /// question) as markable findings, in that order.
    package var findings: [SpecReviewFinding] {
        agreements.map { SpecReviewFinding(key: $0.key, chapter: $0.chapter, text: $0.text, anchor: $0.anchor) }
            + decidedAlone.map { SpecReviewFinding(key: $0.key, chapter: $0.chapter, text: $0.text, anchor: $0.anchor) }
            + blindSpots.map { SpecReviewFinding(key: $0.key, chapter: $0.chapter, text: $0.text, anchor: $0.anchor) }
            + checks.map { SpecReviewFinding(key: $0.key, chapter: $0.chapter, text: $0.question, anchor: nil) }
    }
}

/// A `spec_reviews` row. A `result` that is empty reads as nil; one that does
/// not decode reads as nil with `resultUnreadable` set, so the screen can say
/// so instead of showing an empty review.
package struct SpecReviewRow: FetchableRecord, Equatable, Sendable {
    package enum Status: String, Sendable {
        case queued, running, done, failed, skipped, unknown
    }

    package var askID: Int64
    package var status: Status
    package var reason: String
    package var provider: String
    package var model: String
    package var dropped: Int
    package var attempt: Int
    package var result: SpecReviewResult?
    package var resultUnreadable: Bool

    package init(row: Row) throws {
        askID = row["ask_id"]
        let raw: String = row["status"]
        status = Status(rawValue: raw) ?? .unknown
        reason = row["reason"]
        provider = row["provider"]
        model = row["model"]
        dropped = row["dropped"]
        attempt = row["attempt"]
        let json: String = row["result"]
        if json.isEmpty {
            result = nil
            resultUnreadable = false
        } else if let decoded = try? JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8)) {
            result = decoded
            resultUnreadable = false
        } else {
            result = nil
            resultUnreadable = true
        }
    }
}

package enum SpecReviewMarkState: String, Sendable {
    case ok, comment, viewed
}

/// The owner's mark on a finding (`ch:<n>` keys carry `viewed` for chapters).
package struct SpecReviewMark: Equatable, Sendable {
    package var key: String
    package var state: SpecReviewMarkState
    package var body: String
    /// A comment's finding text, kept with the mark so a comment whose
    /// finding a re-run drops still says what it was about.
    package var about: String

    package init(key: String, state: SpecReviewMarkState, body: String = "", about: String = "") {
        self.key = key
        self.state = state
        self.body = body
        self.about = about
    }
}
