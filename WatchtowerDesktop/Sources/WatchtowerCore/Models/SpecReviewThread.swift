import Foundation

/// The conversation key of a spec review thread (Go
/// `specreview.ThreadContextID`; `internal/specreview/testdata/thread_keys.json`
/// is the shared fixture): `<workbench>:<root>:<key>`, where root is the
/// first ask of the review chain, so a re-round's card with the same item
/// key continues the same thread.
package enum SpecReviewThreadKey {
    /// `chat_conversations.context_type` of a thread (Go
    /// `db.SpecReviewThreadContextType`).
    package static let contextType = "spec_review_thread"

    package static func contextID(workbenchID: Int64, rootAskID: Int64, itemKey: String) -> String {
        "\(workbenchID):\(rootAskID):\(itemKey)"
    }
}

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
/// review**; Go validates the quotes and writes the row, or refuses. A
/// stored one (`spec_review_thread_findings.finding`, Go's `ThreadFinding`)
/// also carries its `key` and `chapter`.
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
    /// Set on a stored finding (`tf:…`); empty on a proposal.
    package var key: String = ""
    /// The chapter of its where-quote, set by Go on a stored finding; empty
    /// (or unknown) lands it in Other.
    package var chapter: String = ""
    package var status: Status = .proposed

    /// The card's head line: the title, else the text.
    package var headline: String { title.isEmpty ? text : title }

    /// The block as `add-finding` reads it on stdin (Go's
    /// `ThreadFindingInput`): `kind`, `severity`, `title`, `text`,
    /// `quote` `{source, text}` and `where` (null when none).
    /// Throws when the block cannot be encoded: nothing is sent then.
    package func blockJSON() throws -> Data {
        let block: [String: Any] = [
            "kind": kind, "severity": severity?.rawValue ?? "", "title": title, "text": text,
            "quote": ["source": quote.source, "text": quote.text],
            "where": anchor.map { ["heading": $0.heading, "quote": $0.quote] as Any } ?? NSNull()
        ]
        return try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
    }

    /// The same finding as one the owner already added: Go's key is made
    /// from the content, and Go stores the title and text as `field` does
    /// (trimmed, at most 600 characters), so both sides are compared that
    /// way: a long or padded proposal still shows as added.
    package func isSameProposal(as other: Self) -> Bool {
        kind == other.kind && Self.storedField(title) == Self.storedField(other.title)
            && Self.storedField(text) == Self.storedField(other.text) && quote == other.quote
    }

    /// Go's `specreview.field`: trimmed, clipped to `maxFieldRunes` runes
    /// (Unicode scalars), trimmed again.
    package static let maxFieldRunes = 600

    package static func storedField(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > maxFieldRunes else { return trimmed }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: trimmed.unicodeScalars.prefix(maxFieldRunes))
        return String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
    }

    private enum Keys: String, CodingKey {
        case kind, severity, title, text, quote, key, chapter
        case anchor = "where"
    }
}
