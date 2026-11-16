import Foundation
import Observation

/// One conversation's feed as the updates leave it (unified chat spec §5.4): a snapshot replaces it, an upsert
/// replaces a message by id or appends it, a conversation update replaces the meta. A resync clears it, and what
/// arrives before the next snapshot is dropped (it would land on a stale feed).
@MainActor
@Observable
public final class ChatFeedStore {
    public private(set) var feed: ChatFeed?

    public init(feed: ChatFeed? = nil) {
        self.feed = feed
    }

    public func apply(_ update: ChatFeedUpdate) {
        switch update {
        case .snapshot(let snapshot):
            feed = snapshot
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
            feed = nil
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
