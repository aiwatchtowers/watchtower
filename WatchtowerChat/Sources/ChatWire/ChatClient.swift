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
    /// Whether the chat can be reached. Contract every client keeps (the models rely on it):
    /// - each access returns a fresh stream for one consumer (a screen and the ⌘/ panel each take their own; ending
    ///   one never ends another), and it starts with the current state;
    /// - after every reconnect the client yields `.connected` again, even when the drop was too short to report any
    ///   other state, so a send waiting on a lost answer goes again.
    var reachability: AsyncStream<ChatReachability> { get }
    /// A new chat is created by its first turn (`chat_turn` with conversation 0, its `projectID` and `routing`), so the
    /// send is kept with the chat's creation (the phone's relay keeps it across a kill). False: the composer sends
    /// `chat_new` first (chat.sock).
    var createsConversationOnTurn: Bool { get }
}

extension ChatClient {
    public var createsConversationOnTurn: Bool { false }
}

/// What `ChatClient.send` throws when the connection dropped before the engine's answer arrived: the operation may
/// or may not have been applied, so a turn goes again with the same `clientKey`. Any other thrown error is a failure
/// of the operation itself and is shown, never retried.
public protocol ChatConnectionError: Error {}

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
