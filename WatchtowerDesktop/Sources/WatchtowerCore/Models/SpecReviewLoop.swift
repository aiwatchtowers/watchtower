import Foundation

/// One author-loop item (Go `specreview.AuthorItem`). Enums stay strings so a
/// value this build does not know is shown neutrally.
package struct SpecReviewLoopItem: Decodable, Equatable, Sendable {
    package struct Reply: Decodable, Equatable, Sendable {
        package var key: String
        /// `fixed` or `disagree`.
        package var reply: String
        package var note: String

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        }

        private enum Keys: String, CodingKey { case key, reply, note }
    }

    package var key: String
    /// `agreement`, `decided_alone`, `blind_spot` or `check`.
    package var kind: String
    package var text: String
    package var note: String
    package var anchor: SpecReviewResult.Anchor?
    package var round: Int
    package var reply: Reply?

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        anchor = try c.decodeIfPresent(SpecReviewResult.Anchor.self, forKey: .anchor)
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        reply = try c.decodeIfPresent(Reply.self, forKey: .reply)
    }

    private enum Keys: String, CodingKey {
        case key, kind, text, note, round, reply
        case anchor = "where"
    }
}

/// A ledger row (Go `specreview.LedgerEntry`): the item fields flattened plus
/// the reviewer's verdict.
package struct SpecReviewLedgerEntry: Decodable, Equatable, Sendable {
    package var item: SpecReviewLoopItem
    /// `resolved`, `disputed` or `unsettled`.
    package var verdict: String
    package var verdictNote: String
    package var settled: Int

    package init(from decoder: Decoder) throws {
        item = try SpecReviewLoopItem(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        verdictNote = try c.decodeIfPresent(String.self, forKey: .verdictNote) ?? ""
        settled = try c.decodeIfPresent(Int.self, forKey: .settled) ?? 0
    }

    private enum Keys: String, CodingKey {
        case verdict, settled
        case verdictNote = "verdict_note"
    }
}

/// Pure reads over a row's author loop.
package enum SpecReviewLoop {
    package static func disputed(_ row: SpecReviewRow) -> [SpecReviewLedgerEntry] {
        row.ledger.filter { $0.verdict == "disputed" || $0.verdict == "unsettled" }
    }

    package static func fixed(_ row: SpecReviewRow) -> [SpecReviewLedgerEntry] {
        row.ledger.filter { $0.verdict == "resolved" }
    }

    package static func endedEarly(_ row: SpecReviewRow) -> Bool {
        !["settled", ""].contains(row.loopEnd)
    }

    package static func endLine(_ row: SpecReviewRow) -> String? {
        switch row.loopEnd {
        case "cap": return "The reviewer and the author did not settle everything in 3 rounds."
        case "reviewer_failed": return "The reviewer stopped before the loop finished."
        case "session_gone": return "The author's session ended before the loop finished."
        case "timeout": return "The author did not answer the reviewer within 30 minutes."
        default: return nil
        }
    }
}
