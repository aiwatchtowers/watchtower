import Foundation
import GRDB
import WatchtowerChatText

/// One thing an `@` mention can point at (spec §6.2).
package struct MentionCandidate: Equatable, Hashable, Sendable, Identifiable {
    package enum Kind: String, Sendable {
        case person, channel, jira, linear, target, track
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

    /// nil for a Jira project or Confluence space hit — those are pinned, not
    /// mentioned.
    package init?(hit: ChatEntityHit) {
        let kind: Kind
        switch hit.kind {
        case .person: kind = .person
        case .channel: kind = .channel
        case .jiraIssue: kind = .jira
        case .linearIssue: kind = .linear
        case .target: kind = .target
        case .track: kind = .track
        case .jiraProject, .confluenceSpace: return nil
        }
        self.init(kind: kind, ref: hit.ref, label: hit.label, detail: hit.detail)
    }

    package var id: String { referenceToken }

    /// `person:<id>`, `channel:<id>`, `jira:<KEY>`, `linear:<KEY>`, `target:<id>`, `track:<id>`.
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

extension MentionTokenizer {
    /// The picked mentions whose `@Label` is still in the text, in pick
    /// order, without duplicates.
    package static func liveMentions(text: String, mentions: [MentionCandidate]) -> [MentionCandidate] {
        var seen = Set<String>()
        return mentions.filter { text.contains($0.insertionText) && seen.insert($0.referenceToken).inserted }
    }
}

/// `@` picker search (spec §6.2): people, Jira and Linear issues, Slack channels,
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
