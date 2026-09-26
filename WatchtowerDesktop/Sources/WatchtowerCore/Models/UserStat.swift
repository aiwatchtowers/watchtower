import Foundation
import GRDB

package struct UserStat: Identifiable, FetchableRecord, Decodable {
    package let id: String
    package let name: String
    package let displayName: String
    package let realName: String
    package let email: String
    package let isBot: Bool
    package let isDeleted: Bool
    package let isBotOverride: Bool?
    package let isMutedForLLM: Bool
    package let totalMessages: Int
    package let channelCount: Int
    package let threadReplies: Int
    package let lastActivity: Double
    package let updatedAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName = "display_name"
        case realName = "real_name"
        case email
        case isBot = "is_bot"
        case isDeleted = "is_deleted"
        case isBotOverride = "is_bot_override"
        case isMutedForLLM = "is_muted_for_llm"
        case totalMessages = "total_messages"
        case channelCount = "channel_count"
        case threadReplies = "thread_replies"
        case lastActivity = "last_activity"
        case updatedAt = "updated_at"
    }

    package var bestName: String {
        if !displayName.isEmpty { return displayName }
        if !realName.isEmpty { return realName }
        if !name.isEmpty { return name }
        return id
    }

    /// Effective bot status considering manual override.
    package var effectiveIsBot: Bool {
        isBotOverride ?? isBot
    }

    package var lastActivityDaysAgo: Int? {
        guard lastActivity > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - lastActivity
        return max(0, Int(age / 86400))
    }
}
