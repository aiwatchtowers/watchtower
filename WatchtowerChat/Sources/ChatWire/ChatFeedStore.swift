import Foundation
import Observation

/// One conversation's feed as the updates leave it (unified chat spec §5.4): a snapshot replaces it, an upsert
/// replaces a message by id or appends it, a conversation update replaces the meta. A resync keeps the last feed on
/// screen (no empty flash) and marks it stale until the fresh snapshot; upserts and conversation updates in the gap
/// still apply to the kept feed (whole messages by id, and the snapshot corrects whatever was lost). `gone` empties
/// it: the conversation was deleted.
@MainActor
@Observable
public final class ChatFeedStore {
    public private(set) var feed: ChatFeed?
    /// Events were lost since `feed`: the next snapshot clears it.
    public private(set) var isStale = false
    /// The conversation no longer exists; a later snapshot (the delete undone) clears it.
    public private(set) var isGone = false

    public init(feed: ChatFeed? = nil) {
        self.feed = feed
    }

    public func apply(_ update: ChatFeedUpdate) {
        switch update {
        case .snapshot(let snapshot):
            feed = snapshot
            isStale = false
            isGone = false
        case .messageUpsert(let message):
            guard let feed else { return }
            var messages = feed.messages
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            self.feed = feed.replacing(messages: messages)
        case .conversation(let conversation):
            guard let feed else { return }
            self.feed = feed.replacing(conversation: conversation)
        case .resync:
            isStale = feed != nil
        case .gone:
            feed = nil
            isStale = false
            isGone = true
        }
    }
}

extension ChatFeed {
    fileprivate func replacing(conversation: Conversation? = nil, messages: [Message]? = nil) -> ChatFeed {
        ChatFeed(
            conversation: conversation ?? self.conversation,
            messages: messages ?? self.messages,
            hasMore: hasMore,
            artifacts: artifacts,
            actions: actions
        )
    }
}
