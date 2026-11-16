import Foundation

/// The `chat_page` slice, record `chat_page-<conversation id>-<before
/// message id>` (iPhone chat spec §4.6): the 60 active-branch messages
/// before that message, in the feed's shape and caps, asked with
/// `chat_page` and kept 5 minutes. Empty when the message left the active
/// branch.
public struct ChatPage: Decodable, Hashable, Sendable {
    /// Oldest first.
    public let messages: [ChatFeed.Message]
    /// Still older messages exist: ask the page before `messages.first`.
    public let hasMore: Bool

    public init(messages: [ChatFeed.Message], hasMore: Bool = false) {
        self.messages = messages
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([ChatFeed.Message].self, forKey: .messages) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case messages, hasMore
    }
}
