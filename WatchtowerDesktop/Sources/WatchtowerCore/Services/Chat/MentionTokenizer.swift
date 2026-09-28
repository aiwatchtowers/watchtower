import Foundation
import GRDB

/// A trigger character's position (UTF-16 offset, the `NSTextView`
/// `selectedRange` unit) and the query typed after it, up to the cursor.
package struct ComposerTrigger: Equatable, Sendable {
    package let start: Int
    package let query: String

    package init(start: Int, query: String) {
        self.start = start
        self.query = query
    }
}

/// A text edit the composer applies: the new text and the caret after it.
package struct ComposerEdit: Equatable, Sendable {
    package let text: String
    package let cursor: Int

    package init(text: String, cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

/// One thing an `@` mention can point at (spec §6.2).
package struct MentionCandidate: Equatable, Hashable, Sendable, Identifiable {
    package enum Kind: String, Sendable {
        case person, channel, jira, target, track
    }

    package let kind: Kind
    package let ref: String
    package let label: String
    package let detail: String

    package init(kind: Kind, ref: String, label: String, detail: String) {
        self.kind = kind
        self.ref = ref
        // A raw newline in the label would break the single-line REFERENCED
        // format (`ChatTurnComposer`) and the `@Label` insertion text — every
        // label source is newline-free by construction today, but nothing
        // enforced it at this boundary (review Minor a).
        self.label = Self.sanitized(label)
        self.detail = detail
    }

    /// nil for a Jira project hit — projects are pinned, not mentioned.
    package init?(hit: ChatEntityHit) {
        let kind: Kind
        switch hit.kind {
        case .person: kind = .person
        case .channel: kind = .channel
        case .jiraIssue: kind = .jira
        case .target: kind = .target
        case .track: kind = .track
        case .jiraProject: return nil
        }
        self.init(kind: kind, ref: hit.ref, label: hit.label, detail: hit.detail)
    }

    package var id: String { referenceToken }

    /// `person:<id>`, `channel:<id>`, `jira:<KEY>`, `target:<id>`, `track:<id>`.
    package var referenceToken: String { "\(kind.rawValue):\(ref)" }

    /// What the picker inserts into the composer text.
    package var insertionText: String { "@\(label)" }

    /// Collapses any newline in a label to a single space — a label is
    /// always rendered/stored on one line.
    private static func sanitized(_ label: String) -> String {
        label.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

package enum MentionTokenizer {
    static let maxQueryLength = 40

    /// The query after an active `@` ending at `cursor`, or nil.
    package static func activeQuery(text: String, cursor: Int) -> String? {
        activeMention(text: text, cursor: cursor)?.query
    }

    /// An `@` opens a mention only at the start of the text or after
    /// whitespace (so `anna@example.com` never does), and the query runs to
    /// the cursor without whitespace.
    package static func activeMention(text: String, cursor: Int) -> ComposerTrigger? {
        trigger(text: text, cursor: cursor, character: "@")
    }

    /// A `/` opens the skill picker only as the first non-whitespace character
    /// of the draft, with a query that is a valid skill-name prefix.
    package static func activeSkill(text: String, cursor: Int) -> ComposerTrigger? {
        guard let trigger = trigger(text: text, cursor: cursor, character: "/") else { return nil }
        let before = String(decoding: Array(text.utf16)[..<trigger.start], as: UTF16.self)
        guard before.allSatisfy(\.isWhitespace) else { return nil }
        guard trigger.query.isEmpty || SkillsCatalog.isValidSkillName(trigger.query) else { return nil }
        return trigger
    }

    /// Replaces `trigger.start ..< cursor` with `replacement`.
    package static func replace(
        _ trigger: ComposerTrigger, in text: String, cursor: Int, with replacement: String
    ) -> ComposerEdit {
        let units = Array(text.utf16)
        let start = max(0, min(trigger.start, units.count))
        let end = max(start, min(cursor, units.count))
        let prefix = String(decoding: units[..<start], as: UTF16.self)
        let suffix = String(decoding: units[end...], as: UTF16.self)
        return ComposerEdit(text: prefix + replacement + suffix, cursor: start + replacement.utf16.count)
    }

    /// The picked mentions whose `@Label` is still in the text, in pick
    /// order, without duplicates.
    package static func liveMentions(text: String, mentions: [MentionCandidate]) -> [MentionCandidate] {
        var seen = Set<String>()
        return mentions.filter { text.contains($0.insertionText) && seen.insert($0.referenceToken).inserted }
    }

    /// Scans back from `cursor` to `character`; nil on whitespace first, on a
    /// non-boundary before the trigger, or on an over-long query.
    static func trigger(text: String, cursor: Int, character: Character) -> ComposerTrigger? {
        let units = Array(text.utf16)
        guard cursor >= 0, cursor <= units.count, let mark = character.utf16.first else { return nil }
        var index = cursor - 1
        while index >= 0 {
            let unit = units[index]
            if unit == mark {
                guard index == 0 || isWhitespace(units[index - 1]) else { return nil }
                let query = String(decoding: units[(index + 1)..<cursor], as: UTF16.self)
                guard query.count <= maxQueryLength else { return nil }
                return ComposerTrigger(start: index, query: query)
            }
            if isWhitespace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

/// `@` picker search (spec §6.2): people, Jira issues, Slack channels,
/// targets, tracks — prefix match, at most 8 results. Label-prefix hits come
/// first; ties keep kind order then each kind's own SQL order.
package enum MentionSearch {
    package static let resultLimit = 8

    package static func search(_ db: Database, query: String) throws -> [MentionCandidate] {
        var hits: [ChatEntityHit] = []
        for kind in [ChatEntityKind.person, .jiraIssue, .channel, .target, .track] {
            hits += try ChatEntitySearch.search(db, kind: kind, query: query, limit: resultLimit)
        }
        let candidates = hits.compactMap(MentionCandidate.init(hit:))
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let lp = labelMatches(lhs.element, needle) ? 0 : 1
            let rp = labelMatches(rhs.element, needle) ? 0 : 1
            return lp != rp ? lp < rp : lhs.offset < rhs.offset
        }
        return Array(ranked.map(\.element).prefix(resultLimit))
    }

    private static func labelMatches(_ candidate: MentionCandidate, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let label = candidate.label.hasPrefix("#") ? String(candidate.label.dropFirst()) : candidate.label
        return label.lowercased().hasPrefix(needle)
    }
}
