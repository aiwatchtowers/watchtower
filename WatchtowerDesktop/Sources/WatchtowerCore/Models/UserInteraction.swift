import GRDB
import Foundation

/// Interaction metrics between two users for a time window (social graph edge).
package struct UserInteraction: FetchableRecord, Decodable, Identifiable, Equatable {
    package let userA: String
    package let userB: String
    package let periodFrom: Double
    package let periodTo: Double
    package let messagesTo: Int
    package let messagesFrom: Int
    package let sharedChannels: Int
    package let threadRepliesTo: Int
    package let threadRepliesFrom: Int
    package let sharedChannelIDs: String
    package let dmMessagesTo: Int
    package let dmMessagesFrom: Int
    package let mentionsTo: Int
    package let mentionsFrom: Int
    package let reactionsTo: Int
    package let reactionsFrom: Int
    package let interactionScore: Double
    package let connectionType: String

    package var id: String { "\(userA)-\(userB)-\(periodFrom)" }

    package enum CodingKeys: String, CodingKey {
        case userA = "user_a"
        case userB = "user_b"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case messagesTo = "messages_to"
        case messagesFrom = "messages_from"
        case sharedChannels = "shared_channels"
        case threadRepliesTo = "thread_replies_to"
        case threadRepliesFrom = "thread_replies_from"
        case sharedChannelIDs = "shared_channel_ids"
        case dmMessagesTo = "dm_messages_to"
        case dmMessagesFrom = "dm_messages_from"
        case mentionsTo = "mentions_to"
        case mentionsFrom = "mentions_from"
        case reactionsTo = "reactions_to"
        case reactionsFrom = "reactions_from"
        case interactionScore = "interaction_score"
        case connectionType = "connection_type"
    }

    /// Total channel messages (both directions, excluding DMs).
    package var totalMessages: Int {
        messagesTo + messagesFrom
    }

    /// Total DM messages (both directions).
    package var totalDMs: Int {
        dmMessagesTo + dmMessagesFrom
    }

    /// Total thread replies (both directions).
    package var totalThreadReplies: Int {
        threadRepliesTo + threadRepliesFrom
    }

    /// Total @-mentions (both directions).
    package var totalMentions: Int {
        mentionsTo + mentionsFrom
    }

    /// Total reactions (both directions).
    package var totalReactions: Int {
        reactionsTo + reactionsFrom
    }

    /// Connection type display label.
    package var connectionTypeLabel: String {
        switch connectionType {
        case "peer": return "Peer"
        case "i_depend": return "I depend on"
        case "depends_on_me": return "Depends on me"
        case "weak": return "Weak signal"
        default: return connectionType
        }
    }

    /// Parsed shared channel IDs from JSON.
    package var parsedSharedChannelIDs: [String] {
        guard let data = sharedChannelIDs.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
