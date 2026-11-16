import ChatWire
import Foundation
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
        // format (the engine's composer) and the `@Label` insertion text — every
        // label source is newline-free by construction today, but nothing
        // enforced it at this boundary (review Minor a).
        self.label = Self.sanitized(label)
        self.detail = detail
    }

    /// nil for a Jira project or Confluence space hit (those are pinned, not mentioned) or a kind this build does
    /// not know (`entity_search`'s hits, Go `chatengine.EntityHit`).
    package init?(hit: ChatEntityHit) {
        guard let kind = Kind(rawValue: hit.kind) else { return nil }
        self.init(kind: kind, ref: hit.id, label: hit.label, detail: hit.detail)
    }

    /// The mention as `chat_turn`'s `compose` carries it (the engine writes the REFERENCED line).
    package var composeMention: ChatCompose.Mention {
        ChatCompose.Mention(kind: kind.rawValue, id: ref, label: label)
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
