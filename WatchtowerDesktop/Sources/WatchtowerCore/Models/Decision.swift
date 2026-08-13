import Foundation

package struct Decision: Codable, Identifiable, Equatable {
    package let text: String
    package let by: String?
    package let messageTS: String?
    package let channelID: String?
    package let importance: String?  // "high", "medium", "low" — nil defaults to "medium"

    package init(text: String, by: String?, messageTS: String?, channelID: String?, importance: String?) {
        self.text = text
        self.by = by
        self.messageTS = messageTS
        self.channelID = channelID
        self.importance = importance
    }

    // M2: stable ID using hash to avoid collisions from underscore separator
    package var id: Int { var hasher = Hasher(); hasher.combine(text); hasher.combine(by); hasher.combine(messageTS); return hasher.finalize() }

    /// Resolved importance level (defaults to "medium" for old digests without this field).
    package var resolvedImportance: String { importance ?? "medium" }

    package enum CodingKeys: String, CodingKey {
        case text, by, importance
        case messageTS = "message_ts"
        case channelID = "channel_id"
    }
}
