import Foundation

/// A question a Discuss thread's agent put to the author (spec 2026-11-08
/// §3; Go's `spec_review_questions`, written by Go only). `thread` is the
/// thread's conversation key.
package struct SpecReviewQuestionRow: Equatable, Sendable, Identifiable {
    package enum State: String, Sendable {
        case open, answered, expired, gone, unknown

        /// A state this build does not know reads as `unknown`.
        package init(raw: String) {
            self = Self(rawValue: raw) ?? .unknown
        }
    }

    package var id: Int64
    package var askID: Int64
    package var thread: String
    package var itemKey: String
    package var question: String
    package var answer: String
    package var state: State

    package init(
        id: Int64,
        askID: Int64,
        thread: String,
        itemKey: String,
        question: String,
        answer: String = "",
        state: State
    ) {
        self.id = id
        self.askID = askID
        self.thread = thread
        self.itemKey = itemKey
        self.question = question
        self.answer = answer
        self.state = state
    }
}

/// A finding a Discuss thread's agent proposes (the Swift mirror of Go's
/// `ThreadFindingInput`, JSON `kind`, `severity`, `title`, `text`,
/// `quote`, `where`). Nothing is added until the owner presses **Add to
/// review**; Go validates the quotes and writes the row, or refuses.
package struct SpecReviewProposedFinding: Decodable, Equatable, Sendable {
    /// Where the quote comes from: `document` or `thread` (the owner's own
    /// words in this thread).
    package struct Quote: Decodable, Equatable, Sendable {
        package var source: String
        package var text: String

        package init(source: String, text: String) {
            self.source = source
            self.text = text
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        }

        private enum Keys: String, CodingKey { case source, text }
    }

    /// The owner's press and Go's answer to it; never in the JSON.
    package enum Status: Equatable, Sendable {
        case proposed
        case added(key: String)
        /// Go's refusal text, such as "not added: quote not found".
        case refused(String)
    }

    /// `differs`, `missing`, `decided_alone` or `blind_spot` (others kept as read).
    package var kind: String
    package var severity: SpecReviewSeverity?
    package var title: String
    package var text: String
    package var quote: Quote
    package var anchor: SpecReviewResult.Anchor?
    package var status: Status = .proposed

    package init(
        kind: String,
        severity: SpecReviewSeverity?,
        title: String,
        text: String,
        quote: Quote,
        anchor: SpecReviewResult.Anchor? = nil,
        status: Status = .proposed
    ) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.text = text
        self.quote = quote
        self.anchor = anchor
        self.status = status
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        severity = SpecReviewSeverity(raw: try c.decodeIfPresent(String.self, forKey: .severity))
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        quote = try c.decodeIfPresent(Quote.self, forKey: .quote) ?? Quote(source: "", text: "")
        anchor = try c.decodeIfPresent(SpecReviewResult.Anchor.self, forKey: .anchor)
    }

    private enum Keys: String, CodingKey {
        case kind, severity, title, text, quote
        case anchor = "where"
    }
}
