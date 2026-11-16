import Foundation

/// The one chat interface the views are written against (unified chat spec §6.1): the Mac's `SocketChatClient`
/// speaks chat.sock to the daemon's engine, the phone's client speaks the relay through the hub.
public protocol ChatClient: Sendable {
    /// Runs one operation and returns the engine's answer.
    func send(_ op: ChatOperation) async throws -> ChatEcho
    /// A conversation's feed: first a snapshot, then the changes.
    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate>
    /// The conversation list: a snapshot whenever it changes.
    func list() -> AsyncStream<ChatListUpdate>
    var reachability: AsyncStream<ChatReachability> { get }
}

/// The engine's answer to an operation.
public enum ChatEcho: Sendable, Equatable {
    case applied(ChatEchoResult)
    /// `code` is busy, not_found, invalid, forbidden, closed, internal or unsupported.
    case refused(code: String, message: String)
}

/// One event of a feed subscription (chat.sock `snapshot`, `message_upsert`, `conversation_update`, `resync`). On
/// the phone every relay record arrives as a snapshot.
public enum ChatFeedUpdate: Sendable {
    case snapshot(ChatFeed)
    /// A whole message, by id.
    case messageUpsert(ChatFeed.Message)
    case conversation(ChatFeed.Conversation)
    /// Events were lost: what is shown is stale until the next snapshot.
    case resync
    /// The conversation no longer exists (deleted). chat.sock sends it as a `snapshot` event without a `snapshot`
    /// (Go `chatengine.Subscription`, which keeps watching and sends a snapshot again if it comes back); the relay
    /// refuses the phone's `chat_feed_request` `not_found` ("This chat no longer exists on your Mac").
    case gone
}

/// One event of the list subscription (chat.sock `snapshot`/`list_update`, `resync`).
public enum ChatListUpdate: Sendable {
    case snapshot(ChatList)
    case resync
}

/// Whether the chat can be reached now.
public enum ChatReachability: Sendable, Equatable {
    case connected
    /// The engine is starting (the daemon is coming up).
    case starting
    case unavailable
    /// The owner stopped Watchtower on purpose.
    case stoppedOnPurpose
    case offline(reason: String)
}
