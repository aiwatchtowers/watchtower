import Foundation

/// A chat.sock subscription event (Go `chatengine.Event`, pushed as `{"event": …, "subscription": …, …}`; the
/// protocol in `internal/chatengine/server.go`) read as a feed or list update.
public struct ChatSocketEvent: Decodable, Sendable {
    /// snapshot, message_upsert, conversation_update, list_update or resync.
    public let event: String
    public let subscription: String
    let snapshot: ChatFeed?
    let message: ChatFeed.Message?
    let conversation: ChatFeed.Conversation?
    let list: ChatList?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        subscription = try c.decodeIfPresent(String.self, forKey: .subscription) ?? ""
        snapshot = try c.decodeIfPresent(ChatFeed.self, forKey: .snapshot)
        message = try c.decodeIfPresent(ChatFeed.Message.self, forKey: .message)
        conversation = try c.decodeIfPresent(ChatFeed.Conversation.self, forKey: .conversation)
        list = try c.decodeIfPresent(ChatList.self, forKey: .list)
    }

    /// The event of a conversation subscription; nil for a list event or one this build does not know. A
    /// `snapshot` without a feed is `gone` (the conversation was deleted).
    public var feedUpdate: ChatFeedUpdate? {
        switch event {
        case "snapshot" where list == nil: snapshot.map { .snapshot($0) } ?? .gone
        case "message_upsert": message.map { .messageUpsert($0) }
        case "conversation_update": conversation.map { .conversation($0) }
        case "resync": .resync
        default: nil
        }
    }

    /// The event of the list subscription (its first `snapshot`, then `list_update`s); nil otherwise.
    public var listUpdate: ChatListUpdate? {
        switch event {
        case "snapshot", "list_update": list.map { .snapshot($0) }
        case "resync": .resync
        default: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case event, subscription, snapshot, message, conversation, list
    }
}
