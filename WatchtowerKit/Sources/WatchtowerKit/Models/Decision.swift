import Foundation

public struct Decision: Codable, Identifiable, Equatable {
    public let text: String
    public let by: String?
    public let messageTS: String?
    public let channelID: String?
    public let importance: String?  // "high", "medium", "low" — nil defaults to "medium"

    // M2: stable ID using hash to avoid collisions from underscore separator
    public var id: Int { var hasher = Hasher(); hasher.combine(text); hasher.combine(by); hasher.combine(messageTS); return hasher.finalize() }

    /// Resolved importance level (defaults to "medium" for old digests without this field).
    public var resolvedImportance: String { importance ?? "medium" }

    enum CodingKeys: String, CodingKey {
        case text, by, importance
        case messageTS = "message_ts"
        case channelID = "channel_id"
    }
}
